import Foundation

public struct ProcessIdentity: Sendable, Hashable, Codable {
    public let pid: Int32
    public let startAbsTime: UInt64

    public var startAbs: UInt64 { startAbsTime }

    public init(pid: Int32, startAbsTime: UInt64) {
        self.pid = pid
        self.startAbsTime = startAbsTime
    }

    public init(pid: Int32, startAbs: UInt64) {
        self.pid = pid
        self.startAbsTime = startAbs
    }
}

public enum AttributionKind: Int, Sendable, Codable, Equatable, Hashable {
    case bundleID = 0
    case executableName = 1
    case processName = 2
}

public enum AppCategory: Int, Sendable, Codable, Equatable, Hashable {
    case userApp = 0
    case macOSService = 1
}

public struct AppKey: Hashable, Sendable, Codable, Equatable {
    public var kind: AttributionKind
    public var value: String

    public init(kind: AttributionKind, value: String) {
        self.kind = kind
        self.value = value
    }
}
