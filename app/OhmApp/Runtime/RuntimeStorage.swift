import Foundation
import OhmLedger

struct RuntimeStorage: Sendable {
    enum Mode: String, Sendable { case appGroup, local }
    let mode: Mode
    let directory: URL

    @concurrent
    static func prepare() async throws -> RuntimeStorage {
        let container = OhmRuntime.appGroupIdentifier().flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        return try select(appGroup: container, local: EnergyLedger.localDataDirectory())
    }

    // A non-nil container URL does not guarantee access in an ad-hoc signed build.
    static func select(appGroup: URL?, local: URL) throws -> RuntimeStorage {
        if let appGroup {
            do {
                try FileManager.default.createDirectory(at: appGroup, withIntermediateDirectories: true)
                let probe = appGroup.appendingPathComponent(".ohm-storage-probe-\(UUID())")
                defer { try? FileManager.default.removeItem(at: probe) }
                try Data().write(to: probe, options: .atomic)
                return RuntimeStorage(mode: .appGroup, directory: appGroup)
            } catch { /* Preview signing can deny access; use private local storage. */ }
        }
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local.path)
        return RuntimeStorage(mode: .local, directory: local)
    }
}
