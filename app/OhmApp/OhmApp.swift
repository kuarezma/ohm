import SwiftUI
import AppKit
import Darwin
import OhmModel

@main
struct OhmApp: App {
    @NSApplicationDelegateAdaptor(OhmAppDelegate.self) private var delegate
    @State private var store = OhmStore()

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--runtime-smoke") {
            guard CommandLine.arguments.count > index + 1,
                  let seconds = Double(CommandLine.arguments[index + 1]),
                  seconds.isFinite, seconds > 0, seconds <= 86_400 else {
                Self.fail("--runtime-smoke için 0 ile 86400 arasında saniye belirtin.")
            }
            var rulesFile: String? = nil
            if let rIndex = CommandLine.arguments.firstIndex(of: "--rules-file"), CommandLine.arguments.count > rIndex + 1 {
                rulesFile = CommandLine.arguments[rIndex + 1]
            }
            Self.runHeadless(seconds: seconds, rulesFile: rulesFile)
        }
        if CommandLine.arguments.contains("--runtime-self-check") {
            _ = NSApplication.shared
            Task {
                do {
                    try OhmAppDelegate.selfCheck()
                    try await OhmRuntime.selfCheck()
                    print("RUNTIME_SELF_CHECK_OK")
                    exit(0)
                } catch { Self.fail(error.localizedDescription) }
            }
            NSApplication.shared.run()
            exit(1)
        }
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
        delegate.source = store.dataSource as? LiveDataSource
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    private static func runHeadless(seconds: Double, rulesFile: String? = nil) -> Never {
        // WatcherProtection inherits stdout, and thawd logs there. Keep the JSON destination in
        // a close-on-exec descriptor and route all runtime/watcher diagnostics to stderr.
        let jsonDescriptor = dup(STDOUT_FILENO)
        guard jsonDescriptor >= 0 else { Self.fail("Smoke çıktı kanalı açılamadı.") }
        guard fcntl(jsonDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(jsonDescriptor)
            Self.fail("Smoke tanı çıktı kanalı ayrılamadı.")
        }
        let jsonOutput = FileHandle(fileDescriptor: jsonDescriptor, closeOnDealloc: true)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let bridge = WorkspaceBridge()
        bridge.setInteractive(true)
        Task(priority: .utility) {
            do {
                let runtime = try await OhmRuntime.make(source: nil, smoke: true, rulesFile: rulesFile)
                await runtime.start(workspace: bridge.events)
                try await Task.sleep(for: .seconds(seconds))
                let report = try await runtime.smokeReport()
                bridge.stop()
                await runtime.shutdown()
                let data = try JSONEncoder().encode(report)
                guard let json = String(data: data, encoding: .utf8) else {
                    Self.fail("Smoke JSON çıktısı oluşturulamadı.")
                }
                jsonOutput.write(Data((json + "\n").utf8))
                exit(0)
            } catch { Self.fail(error.localizedDescription) }
        }
        application.run()
        exit(1)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
                .onAppear { (store.dataSource as? LiveDataSource)?.setInteractive(true) }
                .onDisappear { (store.dataSource as? LiveDataSource)?.setInteractive(false) }
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

@MainActor
protocol AppRuntimeLifecycle: AnyObject {
    func start()
    func shutdown() async
}

@MainActor
final class OhmAppDelegate: NSObject, NSApplicationDelegate {
    var source: (any AppRuntimeLifecycle)? {
        didSet { startSourceIfNeeded() }
    }
    private var sourceStarted = false
    private var terminationStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) { startSourceIfNeeded() }

    private func startSourceIfNeeded() {
        guard !sourceStarted, !terminationStarted, let source else { return }
        // Source attachment must also start the runtime: SwiftUI/AppKit launch order can vary.
        sourceStarted = true
        source.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let source else { return .terminateNow }
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        Task {
            await source.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The terminateLater handshake completes shutdown before this notification.
        terminationStarted = true
        Task { await source?.shutdown() }
    }

    static func selfCheck() throws {
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
        for callbackFirst in [true, false] {
            let delegate = OhmAppDelegate()
            let source = LaunchProbe()
            if callbackFirst { delegate.applicationDidFinishLaunching(notification) }
            delegate.source = source
            guard source.starts == 1 else {
                throw RuntimeError.failure("Kaynak atanınca runtime tam bir kez başlamadı (callbackFirst=\(callbackFirst)).")
            }
            delegate.applicationDidFinishLaunching(notification)
            delegate.applicationDidFinishLaunching(notification)
            delegate.source = source
            guard source.starts == 1 else {
                throw RuntimeError.failure("Tekrarlanan açılış olayları runtime'ı yeniden başlattı.")
            }
        }
        let terminatingDelegate = OhmAppDelegate()
        terminatingDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let lateSource = LaunchProbe()
        terminatingDelegate.source = lateSource
        terminatingDelegate.applicationDidFinishLaunching(notification)
        guard lateSource.starts == 0 else {
            throw RuntimeError.failure("Kapanış başladıktan sonra runtime başlatıldı.")
        }
    }

    private final class LaunchProbe: AppRuntimeLifecycle {
        var starts = 0
        func start() { starts += 1 }
        func shutdown() async {}
    }
}
