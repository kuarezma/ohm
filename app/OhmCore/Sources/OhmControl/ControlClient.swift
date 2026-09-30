import Darwin
import Dispatch
import Foundation

public enum ControlTransportError: Error, Sendable, Equatable, LocalizedError {
    case notRunning, timeout, unauthorized, mismatchedRequest, invalidPath, closed
    case system(Int32)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Ohm çalışmıyor; `open -a Ohm`"
        case .timeout: "Ohm kontrol isteği zaman aşımına uğradı; işlem sonucunu uygulamadan kontrol edin."
        case .unauthorized: "Kontrol soketinin kullanıcı kimliği doğrulanamadı."
        case .mismatchedRequest: "Ohm yanıtının istek kimliği eşleşmiyor."
        case .invalidPath: "Kontrol soketi yolu geçersiz veya çok uzun."
        case .closed: "Ohm kontrol bağlantısı kapandı."
        case .system(let code): "Kontrol bağlantısı hatası: \(String(cString: strerror(code))) (\(code))."
        }
    }
}

/// Blocking POSIX calls run on a dedicated executor, never on the main/cooperative executor.
public actor ControlClient {
    private let queue = DispatchSerialQueue(label: "dev.ohm.control-client", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let path: String

    public init(path: String) { self.path = path }

    public func request(_ request: ControlRequest) throws -> ControlResponse {
        try request.validate()
        let line = try ControlCodec.encode(request)
        let deadline = ControlSocket.deadline(seconds: 5)
        let descriptor = try ControlSocket.connect(path: path, deadline: deadline)
        defer { close(descriptor) }
        guard ControlSocket.peerUID(descriptor) == getuid() else { throw ControlTransportError.unauthorized }
        try ControlSocket.write(line, to: descriptor, deadline: deadline)
        let response = try ControlCodec.decodeResponse(ControlSocket.readLine(from: descriptor, deadline: deadline))
        guard response.id == request.id else { throw ControlTransportError.mismatchedRequest }
        return response
    }
}

/// Shared transport primitives; the app alone owns the listener and its lifetime.
public enum ControlSocket {
    public static func path() throws -> String {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 1, count < 4096 else { throw ControlTransportError.invalidPath }
        var buffer = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, count) == count else {
            throw ControlTransportError.invalidPath
        }
        let directory = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let path = directory + "dev.ohm.control.sock"
        _ = try address(path: path)
        return path
    }

    public static func address(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = path.utf8CString
        guard path.hasPrefix("/"), !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlTransportError.invalidPath
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            for (index, byte) in bytes.enumerated() { storage[index] = UInt8(bitPattern: byte) }
        }
        return address
    }

    public static func makeDescriptor() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlTransportError.system(errno) }
        do { try configure(descriptor); return descriptor }
        catch { close(descriptor); throw error }
    }

    public static func configure(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        var enabled: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ControlTransportError.system(errno)
        }
    }

    public static func peerUID(_ descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        return uid
    }

    public static func deadline(seconds: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
    }

    public static func connect(path: String, deadline: UInt64) throws -> Int32 {
        let descriptor = try makeDescriptor()
        do {
            var address = try address(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                let code = errno
                if code == ENOENT || code == ECONNREFUSED { throw ControlTransportError.notRunning }
                guard code == EINPROGRESS || code == EAGAIN else { throw ControlTransportError.system(code) }
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
                    throw ControlTransportError.system(errno)
                }
                if socketError == ENOENT || socketError == ECONNREFUSED { throw ControlTransportError.notRunning }
                guard socketError == 0 else { throw ControlTransportError.system(socketError) }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    public static func readLine(from descriptor: Int32, deadline: UInt64) throws -> Data {
        var frame = ControlLineBuffer()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !frame.isComplete {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { throw ControlTransportError.closed }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw ControlTransportError.system(errno)
            }
            try frame.append(Data(buffer.prefix(count)))
        }
        return frame.data
    }

    public static func write(_ data: Data, to descriptor: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw ControlTransportError.system(errno)
                }
                guard count > 0 else { throw ControlTransportError.closed }
                offset += count
            }
        }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ControlTransportError.timeout }
            let milliseconds = Int32(min(UInt64(Int32.max), max(1, (deadline - now) / 1_000_000)))
            var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&descriptorState, 1, milliseconds)
            if result < 0 {
                if errno == EINTR { continue }
                throw ControlTransportError.system(errno)
            }
            if result == 0 { throw ControlTransportError.timeout }
            guard descriptorState.revents & Int16(POLLNVAL) == 0 else { throw ControlTransportError.closed }
            return // recv/SO_ERROR reports EOF, POLLHUP and socket errors precisely.
        }
    }
}
