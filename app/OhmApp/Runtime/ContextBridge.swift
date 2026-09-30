import AppKit
import Foundation
import IOKit.ps
import OhmModel
import OSLog

public enum ContextTrigger: Sendable {
    case thermal(ThermalLevel)
    case powerSource
    case deadline
}

@MainActor
public final class ContextBridge {
    public let triggers: AsyncStream<ContextTrigger>
    private let continuation: AsyncStream<ContextTrigger>.Continuation
    private var thermalObserver: NSObjectProtocol?
    private var powerSourceRunLoopSource: CFRunLoopSource?

    public init() {
        (triggers, continuation) = AsyncStream.makeStream()
        setupThermalObserver()
        setupPowerSourceObserver()
    }

    private func setupThermalObserver() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let level: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .nominal
            }
            self?.continuation.yield(.thermal(level))
        }
    }

    private func setupPowerSourceObserver() {
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
            guard let context else { return }
            let bridge = Unmanaged<ContextBridge>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                bridge.continuation.yield(.powerSource)
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = source
        }
    }

    public func stop() {
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
        continuation.finish()
    }
}
