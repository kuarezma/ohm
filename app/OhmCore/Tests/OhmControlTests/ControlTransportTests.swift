import Darwin
import Dispatch
import Foundation
import Testing
@testable import OhmControl

@Suite("OhmControl bounded transport")
struct ControlTransportTests {
    private func socketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw ControlTransportError.system(errno)
        }
        do {
            try ControlSocket.configure(descriptors[0])
            try ControlSocket.configure(descriptors[1])
            return (descriptors[0], descriptors[1])
        } catch {
            close(descriptors[0]); close(descriptors[1]); throw error
        }
    }

    @Test func splitRoundTripAndPeerIdentity() throws {
        let (writer, reader) = try socketPair()
        defer { close(writer); close(reader) }
        #expect(ControlSocket.peerUID(reader) == getuid())
        #expect(ControlSocket.peerUID(-1) == nil)
        let request = ControlRequest(operation: .freeze, target: "Örnek")
        let line = try ControlCodec.encode(request)
        let deadline = ControlSocket.deadline(seconds: 1)
        try ControlSocket.write(line.prefix(3), to: writer, deadline: deadline)
        try ControlSocket.write(line.dropFirst(3), to: writer, deadline: deadline)
        #expect(try ControlCodec.decodeRequest(ControlSocket.readLine(from: reader, deadline: deadline)) == request)
    }

    @Test func incompleteEOFIsNotACommand() throws {
        let (writer, reader) = try socketPair()
        defer { close(reader) }
        try ControlSocket.write(Data("{\"version\":1".utf8), to: writer, deadline: ControlSocket.deadline(seconds: 1))
        close(writer)
        #expect(throws: ControlTransportError.closed) {
            try ControlSocket.readLine(from: reader, deadline: ControlSocket.deadline(seconds: 1))
        }
    }

    @Test func incompleteFrameHasAnAbsoluteDeadline() throws {
        let (writer, reader) = try socketPair()
        defer { close(writer); close(reader) }
        try ControlSocket.write(Data("{".utf8), to: writer, deadline: ControlSocket.deadline(seconds: 1))
        let started = DispatchTime.now().uptimeNanoseconds
        #expect(throws: ControlTransportError.timeout) {
            try ControlSocket.readLine(from: reader, deadline: started + 100_000_000)
        }
        #expect(DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000)
    }

    @Test func closedPeerCannotKillTheWriterWithSIGPIPE() throws {
        let (writer, reader) = try socketPair()
        defer { close(writer) }
        close(reader)
        #expect(throws: (any Error).self) {
            try ControlSocket.write(Data([0x0A]), to: writer, deadline: ControlSocket.deadline(seconds: 1))
        }
    }

    @Test func pathLengthAndEmbeddedNULAreRejected() {
        for path in ["relative.sock", "/tmp/\0socket", "/" + String(repeating: "x", count: 104)] {
            #expect(throws: ControlTransportError.invalidPath) { try ControlSocket.address(path: path) }
        }
        #expect(throws: ControlTransportError.notRunning) {
            try ControlSocket.connect(path: "/tmp/ohm-missing-\(UUID().uuidString)", deadline: ControlSocket.deadline(seconds: 1))
        }
    }
}
