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

        if let code = localeCode?.lowercased() {
            let locale = Locale(identifier: code)
            let isTurkish = code.starts(with: "tr")

            if isTurkish {
                // 1. popover-light-tr.png
                render(
                    view: PopoverView(store: normalStore),
                    locale: locale,
                    colorScheme: .light,
                    size: CGSize(width: 360, height: 420),
                    to: outputURL.appendingPathComponent("popover-light-tr.png")
                )

                // 2. popover-runaway-tr.png
                render(
                    view: PopoverView(store: runawayStore),
                    locale: locale,
                    colorScheme: .dark,
                    size: CGSize(width: 360, height: 490),
                    to: outputURL.appendingPathComponent("popover-runaway-tr.png")
                )

                // 3. onboarding-tr.png
                render(
                    view: OnboardingView(onDismiss: {}),
                    locale: locale,
                    colorScheme: .dark,
                    size: CGSize(width: 480, height: 380),
                    to: outputURL.appendingPathComponent("onboarding-tr.png")
                )

                // Compatibility files
                render(
                    view: PopoverView(store: normalStore),
                    locale: locale,
                    colorScheme: .dark,
                    size: CGSize(width: 360, height: 420),
                    to: outputURL.appendingPathComponent("popover-dark.png")
                )
                render(
                    view: PopoverView(store: runawayStore),
                    locale: locale,
                    colorScheme: .dark,
                    size: CGSize(width: 360, height: 490),
                    to: outputURL.appendingPathComponent("popover-runaway.png")
                )
                render(
                    view: OnboardingView(onDismiss: {}),
                    locale: locale,
                    colorScheme: .dark,
                    size: CGSize(width: 480, height: 380),
                    to: outputURL.appendingPathComponent("onboarding.png")
                )
            } else {
                // 1. popover-light-en.png
                render(
                    view: PopoverView(store: normalStore),
                    locale: locale,
                    colorScheme: .light,
                    size: CGSize(width: 360, height: 420),
                    to: outputURL.appendingPathComponent("popover-light-en.png")
                )

                // 2. popover-dark-en.png
                render(
                    view: PopoverView(store: normalStore),
                    locale: locale,
                    colorScheme: .dark,
                    size: CGSize(width: 360, height: 420),
                    to: outputURL.appendingPathComponent("popover-dark-en.png")
                )

                // Compatibility file
                render(
                    view: PopoverView(store: normalStore),
                    locale: locale,
                    colorScheme: .light,
                    size: CGSize(width: 360, height: 420),
                    to: outputURL.appendingPathComponent("popover-light.png")
                )
            }
        } else {
            // Render all variants (EN + TR) when no specific locale is provided
            let enLocale = Locale(identifier: "en")
            let trLocale = Locale(identifier: "tr")

            // English variants
            render(
                view: PopoverView(store: normalStore),
                locale: enLocale,
                colorScheme: .light,
                size: CGSize(width: 360, height: 420),
                to: outputURL.appendingPathComponent("popover-light-en.png")
            )

            // Turkish variants
            render(
                view: PopoverView(store: normalStore),
                locale: trLocale,
                colorScheme: .light,
                size: CGSize(width: 360, height: 420),
                to: outputURL.appendingPathComponent("popover-light-tr.png")
            )
            render(
                view: PopoverView(store: runawayStore),
                locale: trLocale,
                colorScheme: .dark,
                size: CGSize(width: 360, height: 490),
                to: outputURL.appendingPathComponent("popover-runaway-tr.png")
            )
            render(
                view: OnboardingView(onDismiss: {}),
                locale: trLocale,
                colorScheme: .dark,
                size: CGSize(width: 480, height: 380),
                to: outputURL.appendingPathComponent("onboarding-tr.png")
            )

            // Base filenames for general review
            render(
                view: PopoverView(store: normalStore),
                locale: trLocale,
                colorScheme: .light,
                size: CGSize(width: 360, height: 420),
                to: outputURL.appendingPathComponent("popover-light.png")
            )
            render(
                view: PopoverView(store: normalStore),
                locale: trLocale,
                colorScheme: .dark,
                size: CGSize(width: 360, height: 420),
                to: outputURL.appendingPathComponent("popover-dark.png")
            )
            render(
                view: PopoverView(store: runawayStore),
                locale: trLocale,
                colorScheme: .dark,
                size: CGSize(width: 360, height: 490),
                to: outputURL.appendingPathComponent("popover-runaway.png")
            )
            render(
                view: OnboardingView(onDismiss: {}),
                locale: trLocale,
                colorScheme: .dark,
                size: CGSize(width: 480, height: 380),
                to: outputURL.appendingPathComponent("onboarding.png")
            )
        }

        print("Rendered previews successfully to: \(outputURL.path)")
    }

    private static func render<V: View>(view: V, locale: Locale, colorScheme: ColorScheme, size: CGSize, to fileURL: URL) {
        let themedView = view
            .environment(\.locale, locale)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme)
            .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: themedView)
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
