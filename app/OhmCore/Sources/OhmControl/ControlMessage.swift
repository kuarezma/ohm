import Foundation
import OhmModel

public enum ControlOperation: String, Sendable, Codable {
    case top, eCore, freeze, thaw, thawAll
}

public struct ControlRequest: Sendable, Codable, Equatable {
    public var version: Int
    public var id: UUID
    public var operation: ControlOperation
    public var target: String?
    public var off: Bool

    public init(version: Int = 1, id: UUID = UUID(), operation: ControlOperation,
                target: String? = nil, off: Bool = false) {
        self.version = version
        self.id = id
        self.operation = operation
        self.target = target
        self.off = off
    }

    public func validate() throws {
        guard version == ControlCodec.version else { throw ControlProtocolError.unsupportedVersion(version) }
        if let target {
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  target.utf8.count <= 256, !target.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw ControlProtocolError.invalidArguments
            }
        }
        switch operation {
        case .top, .thawAll:
            guard target == nil, !off else { throw ControlProtocolError.invalidArguments }
        case .eCore:
            guard target != nil else { throw ControlProtocolError.invalidArguments }
        case .freeze, .thaw:
            guard target != nil, !off else { throw ControlProtocolError.invalidArguments }
        }
    }
}

public enum ControlErrorCode: String, Sendable, Codable {
    case malformed, tooLarge, unsupportedVersion, invalidArguments, unauthorized
    case notReady, notFound, ambiguousTarget, vetoed, rolledBack, recoveryPending, internalError
}

public struct ControlFailure: Sendable, Codable, Equatable {
    public let code: ControlErrorCode
    public let vetoes: [FreezeVeto]

    public init(code: ControlErrorCode, vetoes: [FreezeVeto] = []) {
        self.code = code
        self.vetoes = vetoes
    }
}

public struct ControlProcess: Sendable, Codable, Equatable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let watts: Double

    public init(pid: Int32, name: String, cpuPercent: Double, watts: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.watts = watts
    }
}

public struct ControlTop: Sendable, Codable, Equatable {
    public let sampledAt: Date
    public let watts: Double
    public let processes: [ControlProcess]

    public init(sampledAt: Date, watts: Double, processes: [ControlProcess]) {
        self.sampledAt = sampledAt
        self.watts = watts
        self.processes = processes
    }
}

public struct ControlResponse: Sendable, Codable, Equatable {
    public let version: Int
    public let id: UUID
    public let message: String
    public let error: ControlFailure?
    public let top: ControlTop?
    public var success: Bool { error == nil }

    public init(version: Int = 1, id: UUID, message: String, error: ControlFailure? = nil,
                top: ControlTop? = nil) {
        self.version = version
        self.id = id
        self.message = message
        self.error = error
        self.top = top
    }
}

public enum ControlProtocolError: Error, Sendable, Equatable {
    case malformed, tooLarge, unsupportedVersion(Int), invalidArguments
}

public enum ControlCodec {
    public static let version = 1
    /// Includes the terminating newline. Both directions use the same bound.
    public static let maxLineBytes = 65_536

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var line = try encoder.encode(value)
        line.append(0x0A)
        guard line.count <= maxLineBytes else { throw ControlProtocolError.tooLarge }
        return line
    }

    public static func decodeRequest(_ line: Data) throws -> ControlRequest {
        let request: ControlRequest = try decode(line)
        try request.validate()
        return request
    }

    public static func decodeResponse(_ line: Data) throws -> ControlResponse {
        let response: ControlResponse = try decode(line)
        guard response.version == version else { throw ControlProtocolError.unsupportedVersion(response.version) }
        return response
    }

    private static func decode<T: Decodable>(_ line: Data) throws -> T {
        guard line.count <= maxLineBytes else { throw ControlProtocolError.tooLarge }
        guard line.last == 0x0A, !line.dropLast().contains(0x0A) else { throw ControlProtocolError.malformed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(T.self, from: line.dropLast()) }
        catch { throw ControlProtocolError.malformed }
    }
}

/// A connection carries exactly one request and one response; no unbounded pipelining.
public struct ControlLineBuffer: Sendable {
    public private(set) var data = Data()
    public var count: Int { data.count }
    public var isComplete: Bool { data.last == 0x0A }
    public init() {}

    public mutating func append(_ chunk: Data) throws {
        guard chunk.count <= ControlCodec.maxLineBytes - data.count else { throw ControlProtocolError.tooLarge }
        guard !isComplete, !chunk.dropLast().contains(0x0A) else { throw ControlProtocolError.malformed }
        data.append(chunk)
    }
}
