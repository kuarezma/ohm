import Foundation
import Testing
@testable import OhmControl
import OhmModel

@Suite("OhmControl JSON Lines")
struct ControlMessageTests {
    @Test func requestRoundTrip() throws {
        let request = ControlRequest(operation: .eCore, target: "Slack", off: true)
        let line = try ControlCodec.encode(request)
        #expect(line.last == 0x0A)
        let decoded = try ControlCodec.decodeRequest(line)
        #expect(decoded == request)
    }

    @Test func responseRoundTrip() throws {
        let request = ControlRequest(operation: .top)
        let response = ControlResponse(id: request.id, message: "Hazır", top: ControlTop(
            sampledAt: Date(timeIntervalSince1970: 100), watts: 3,
            processes: [ControlProcess(pid: 42, name: "Örnek", cpuPercent: 10, watts: 1)]))
        let decoded = try ControlCodec.decodeResponse(ControlCodec.encode(response))
        #expect(decoded == response)
    }

    @Test func malformedAndIncompleteLines() {
        for line in [Data("garbage\n".utf8), Data("{}\n".utf8), Data("{}".utf8),
                     Data("{}\n{}\n".utf8), Data([0xFF, 0x0A])] {
            #expect(throws: (any Error).self) { try ControlCodec.decodeRequest(line) }
        }
    }

    @Test func oversizeFrameIsRejectedBeforeAccumulating() throws {
        var frame = ControlLineBuffer()
        try frame.append(Data(repeating: 0x20, count: ControlCodec.maxLineBytes - 1))
        #expect(throws: ControlProtocolError.tooLarge) { try frame.append(Data([0x20, 0x0A])) }
        #expect(frame.count <= ControlCodec.maxLineBytes)
        #expect(throws: ControlProtocolError.tooLarge) {
            try ControlCodec.decodeRequest(Data(repeating: 0x20, count: ControlCodec.maxLineBytes + 1))
        }
    }

    @Test func splitFrameAndExtraLine() throws {
        let request = ControlRequest(operation: .thawAll)
        let line = try ControlCodec.encode(request)
        var frame = ControlLineBuffer()
        try frame.append(line.prefix(5))
        #expect(!frame.isComplete)
        try frame.append(line.dropFirst(5))
        #expect(frame.isComplete)
        #expect(try ControlCodec.decodeRequest(frame.data) == request)
        #expect(throws: ControlProtocolError.malformed) { try frame.append(Data([0x0A])) }
    }

    @Test func versionMismatch() throws {
        let request = ControlRequest(version: 99, operation: .top)
        #expect(throws: ControlProtocolError.unsupportedVersion(99)) {
            try ControlCodec.decodeRequest(ControlCodec.encode(request))
        }
        let response = ControlResponse(version: 99, id: request.id, message: "")
        #expect(throws: ControlProtocolError.unsupportedVersion(99)) {
            try ControlCodec.decodeResponse(ControlCodec.encode(response))
        }
    }

    @Test func invalidArguments() {
        for request in [ControlRequest(operation: .freeze),
                        ControlRequest(operation: .eCore, target: "  "),
                        ControlRequest(operation: .top, target: "Slack"),
                        ControlRequest(operation: .freeze, target: "42", off: true),
                        ControlRequest(operation: .thawAll, target: "42"),
                        ControlRequest(operation: .thaw, target: String(repeating: "x", count: 257))] {
            #expect(throws: ControlProtocolError.invalidArguments) { try request.validate() }
        }
    }
}
