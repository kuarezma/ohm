import Foundation

public struct ProcessIdentity: Sendable, Hashable, Codable {
    public let pid: Int32
    public let startAbsTime: UInt64

    public init(pid: Int32, startAbsTime: UInt64) {
        self.pid = pid
        self.startAbsTime = startAbsTime
    }
}
