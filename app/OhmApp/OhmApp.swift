import SwiftUI
import AppKit
import OhmModel

@main
struct OhmApp: App {
    @State private var store = OhmStore()

    init() {
        if let idx = CommandLine.arguments.firstIndex(of: "--render-previews") {
            _ = NSApplication.shared
            var outputDir = "build/previews"
            if CommandLine.arguments.count > idx + 1 && !CommandLine.arguments[idx + 1].starts(with: "--") {
                outputDir = CommandLine.arguments[idx + 1]
            }

            var requestedLocale: String? = nil
            if let localeIdx = CommandLine.arguments.firstIndex(of: "--locale"),
               CommandLine.arguments.count > localeIdx + 1 {
                requestedLocale = CommandLine.arguments[localeIdx + 1]
            }

            PreviewRenderer.renderAll(to: outputDir, localeCode: requestedLocale)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
