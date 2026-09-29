import SwiftUI
import AppKit

@MainActor
public enum PreviewRenderer {
    public static func renderAll(to directoryPath: String, localeCode: String? = nil) {
        let fileManager = FileManager.default
        let outputURL = URL(fileURLWithPath: directoryPath)

        do {
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
            print("Error creating directory: \(error)")
        }

        let normalStore = OhmStore(dataSource: PreviewDataSource.normal)
        let runawayStore = OhmStore(dataSource: PreviewDataSource.runaway)

        let localeCodes = localeCode.map { [$0.lowercased().hasPrefix("tr") ? "tr" : "en"] } ?? ["tr", "en"]
        for code in localeCodes {
            let locale = Locale(identifier: code)
            for colorScheme in [ColorScheme.light, .dark] {
                let appearanceName = colorScheme == .light ? "light" : "dark"
                render(
                    view: PopoverView(store: normalStore),
                    locale: locale,
                    colorScheme: colorScheme,
                    to: outputURL.appendingPathComponent("popover-\(appearanceName)-\(code).png")
                )
            }
            render(
                view: PopoverView(store: runawayStore),
                locale: locale,
                colorScheme: .dark,
                to: outputURL.appendingPathComponent("popover-runaway-\(code).png")
            )
            render(
                view: OnboardingView(onDismiss: {}),
                locale: locale,
                colorScheme: .dark,
                to: outputURL.appendingPathComponent("onboarding-\(code).png")
            )
        }

        print("Rendered previews successfully to: \(outputURL.path)")
    }

    private static func render<V: View>(view: V, locale: Locale, colorScheme: ColorScheme, to fileURL: URL) {
        let themedView = view
            .environment(\.locale, locale)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme)
            .fixedSize(horizontal: false, vertical: true)

        let hostingView = NSHostingView(rootView: themedView)
        // Use the view's content height rather than centering it in a fixed canvas.
        let size = hostingView.fittingSize
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = colorScheme == .dark ? NSColor(calibratedWhite: 0.12, alpha: 1.0) : NSColor(calibratedWhite: 0.96, alpha: 1.0)
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            if let pngData = rep.representation(using: .png, properties: [:]) {
                do {
                    try pngData.write(to: fileURL)
                    print("Generated: \(fileURL.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
                    return
                } catch {
                    print("Error writing png: \(error)")
                }
            }
        }

        // ImageRenderer fallback
        let renderer = ImageRenderer(content: themedView)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(size)
        if let nsImage = renderer.nsImage,
           let tiffData = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
            print("Generated via ImageRenderer fallback: \(fileURL.path)")
        }
    }
}
