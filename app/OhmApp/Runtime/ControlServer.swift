import Darwin
import Dispatch
import Foundation
import OhmControl
import OSLog

private struct ControlListenerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The lock serializes startup; inode checks keep cleanup from unlinking a replacement file.
private final class ControlListener: Sendable {
    let descriptor: Int32
    private let lock: Int32
    private let path: String
    private let device: dev_t
    private let inode: ino_t

    init(path: String) throws {
        let lock = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ControlTransportError.system(errno) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == getuid(),
              lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_nlink == 1,
              fchmod(lock, 0o600) == 0 else {
            close(lock)
            throw ControlTransportError.unauthorized
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw ControlListenerError(message: "Ohm kontrol soketi başka bir uygulama örneğinde açık.")
        }
        var descriptor: Int32 = -1
        var boundInfo: stat?
        do {
            var existing = stat()
            if lstat(path, &existing) == 0 {
                guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else {
                    throw ControlTransportError.unauthorized
                }
                // Never replace a live endpoint, including one from an older Ohm version.
                do {
                    let probe = try ControlSocket.connect(path: path, deadline: ControlSocket.deadline(seconds: 1))
                    close(probe)
                    throw ControlListenerError(message: "Ohm kontrol soketi zaten kullanımda.")
                } catch ControlTransportError.notRunning {
                    var current = stat()
                    guard lstat(path, &current) == 0, current.st_dev == existing.st_dev,
                          current.st_ino == existing.st_ino, unlink(path) == 0 else {
                        throw ControlTransportError.unauthorized
                    }
                }
            } else if errno != ENOENT { throw ControlTransportError.system(errno) }

            descriptor = try ControlSocket.makeDescriptor()
            var address = try ControlSocket.address(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw ControlTransportError.system(errno) }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw ControlTransportError.system(errno) }
            boundInfo = info
            // Set permissions before listen: the transient umask cannot expose a usable endpoint.
            guard chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
                throw ControlTransportError.system(errno)
            }
            self.descriptor = descriptor
            self.lock = lock
            self.path = path
            device = info.st_dev
            inode = info.st_ino
        } catch {
            if descriptor >= 0 { close(descriptor) }
            if let boundInfo { Self.remove(path, device: boundInfo.st_dev, inode: boundInfo.st_ino) }
            close(lock)
            throw error
        }
    }

    func removePath() { Self.remove(path, device: device, inode: inode) }

    private static func remove(_ path: String, device: dev_t, inode: ino_t) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == device, info.st_ino == inode,
           info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
    }

    deinit { removePath(); close(lock) }
}

/// Each of at most eight peers has a serial executor and a single owned descriptor.
private actor ControlConnection {
    private let queue = DispatchSerialQueue(label: "dev.ohm.control-peer", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    func expire() {
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        descriptor = -1
    }

    func run(handler: @Sendable (ControlRequest) async -> ControlResponse) async {
        var id = UUID()
        do {
            let line = try ControlSocket.readLine(from: descriptor, deadline: ControlSocket.deadline(seconds: 2))
            struct Header: Decodable { let id: UUID }
            if let header = try? JSONDecoder().decode(Header.self, from: line) { id = header.id }
            let request = try ControlCodec.decodeRequest(line)
            guard !Task.isCancelled, descriptor >= 0 else { expire(); return }
            let response = await handler(request)
            // A deadline may have closed the socket while the Governor was processing the request.
            guard !Task.isCancelled, descriptor >= 0 else { expire(); return }
            try ControlSocket.write(ControlCodec.encode(response), to: descriptor, deadline: ControlSocket.deadline(seconds: 1))
        } catch let error as ControlProtocolError {
            let code: ControlErrorCode = switch error {
            case .tooLarge: .tooLarge
            case .unsupportedVersion: .unsupportedVersion
            case .invalidArguments: .invalidArguments
            case .malformed: .malformed
            }
            let response = ControlResponse(id: id, message: "Kontrol mesajı reddedildi: \(code.rawValue).",
                                           error: ControlFailure(code: code))
            if descriptor >= 0, let data = try? ControlCodec.encode(response) {
                try? ControlSocket.write(data, to: descriptor, deadline: ControlSocket.deadline(seconds: 1))
            }
        } catch {
            Logger(subsystem: "dev.ohm", category: "control").debug("peer closed: \(String(describing: error), privacy: .public)")
        }
        expire()
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}

actor ControlServer {
    private struct Peer {
        let connection: ControlConnection
        let worker: Task<Void, Never>
        let timer: Task<Void, Never>
    }

    private let handler: @Sendable (ControlRequest) async -> ControlResponse
    private var listener: ControlListener?
    private var source: (any DispatchSourceRead)?
    private var acceptTask: Task<Void, Never>?
    private var peers: [UUID: Peer] = [:]

    init(handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) { self.handler = handler }

    func start(path: String? = nil) throws {
        guard listener == nil else { return }
        let listener = try ControlListener(path: try path ?? ControlSocket.path())
        self.listener = listener
        let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeReadSource(fileDescriptor: listener.descriptor,
                                                   queue: DispatchQueue(label: "dev.ohm.control-listener"))
        source.setEventHandler { continuation.yield(()) }
        // Dispatch owns the listening descriptor until cancellation completes.
        source.setCancelHandler { close(listener.descriptor); continuation.finish() }
        self.source = source
        acceptTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { break }
                await self?.acceptReady()
            }
        }
        source.resume()
    }

    private func acceptReady() {
        guard let listener else { return }
        // Bound work even if the backlog is continuously replenished.
        for _ in 0..<16 {
            let descriptor = accept(listener.descriptor, nil, nil)
            guard descriptor >= 0 else { break }
            guard ControlSocket.peerUID(descriptor) == getuid() else {
                Logger(subsystem: "dev.ohm", category: "control").error("rejected peer: UID mismatch or getpeereid failed")
                close(descriptor)
                continue
            }
            guard peers.count < 8 else { close(descriptor); continue }
            do { try ControlSocket.configure(descriptor) }
            catch { close(descriptor); continue }
            let id = UUID()
            let connection = ControlConnection(descriptor: descriptor)
            let handler = handler
            let worker = Task { [weak self] in
                await connection.run(handler: handler)
                await self?.finished(id)
            }
            let timer = Task {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                worker.cancel()
                await connection.expire()
            }
            peers[id] = Peer(connection: connection, worker: worker, timer: timer)
        }
    }

    private func finished(_ id: UUID) {
        peers.removeValue(forKey: id)?.timer.cancel()
    }

    func stop() async {
        source?.cancel()
        source = nil
        acceptTask?.cancel()
        await acceptTask?.value
        acceptTask = nil
        listener?.removePath()
        listener = nil
        let active = Array(peers.values)
        peers.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for peer in active {
                peer.worker.cancel()
                peer.timer.cancel()
                group.addTask { await peer.connection.expire() }
            }
        }
    }
}
