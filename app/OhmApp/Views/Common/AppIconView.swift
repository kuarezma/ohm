import SwiftUI
import AppKit

public struct AppIconView: View {
    public let bundleID: String?
    public let executablePath: String?
    public let appName: String
    public var size: CGFloat

    public init(
        bundleID: String? = nil,
        executablePath: String? = nil,
        appName: String,
        size: CGFloat = 20
    ) {
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.appName = appName
        self.size = size
    }

    public var body: some View {
        if let icon = resolvedIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(.secondary)
        }
    }

    private var resolvedIcon: NSImage? {
        // 1. Resolve via bundle identifier
        if let bundleID = bundleID, !bundleID.isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        // 2. Fall back to bundle / executable path if bundle ID lookup fails
        if let path = executablePath, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        // 3. Fall back to common standard system application locations by name
        let candidatePaths = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            "/System/Applications/Utilities/\(appName).app"
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        // 4. App not installed: return nil to render SF Symbol "app.dashed"
        return nil
    }
}
