import OhmModel
import Synchronization

/// Single-consumer pull stream: AsyncStream itself stores no additional pending ticks.
final class TickBuffer: Sendable {
    private struct State: Sendable {
        var pending: [SampleTick] = []
        var waiter: CheckedContinuation<SampleTick?, Never>?
        var finished = false
    }
    private let state = Mutex(State())
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "Tick buffer capacity must be positive")
        self.capacity = capacity
    }

    var count: Int { state.withLock { $0.pending.count } }

    func offer(_ tick: SampleTick) {
        let waiter = state.withLock { state -> CheckedContinuation<SampleTick?, Never>? in
            guard !state.finished else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.pending.append(tick)
            if state.pending.count > capacity {
                // Prefer the oldest same-source neighbours; otherwise preserve totals across the boundary.
                let index = (0..<(state.pending.count - 1)).first { i in
                    state.pending[i].battery.source == state.pending[i + 1].battery.source
                        && state.pending[i].system.systemSource == state.pending[i + 1].system.systemSource
                } ?? 0
                state.pending[index] = TickCoalescer.merge(state.pending[index], state.pending[index + 1])
                state.pending.remove(at: index + 1)
            }
            return nil
        }
        waiter?.resume(returning: tick)
    }

    func next() async -> SampleTick? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> (Bool, SampleTick?) in
                    if state.finished || Task.isCancelled { return (true, nil) }
                    if !state.pending.isEmpty { return (true, state.pending.removeFirst()) }
                    precondition(state.waiter == nil, "Tick stream supports one consumer")
                    state.waiter = continuation
                    return (false, nil)
                }
                if immediate.0 { continuation.resume(returning: immediate.1) }
            }
        } onCancel: {
            self.finish()
        }
    }

    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<SampleTick?, Never>? in
            state.finished = true
            state.pending.removeAll()
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}
