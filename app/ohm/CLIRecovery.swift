import Dispatch
import OhmJournal

actor CLIRecovery {
    private let queue = DispatchSerialQueue(label: "dev.ohm.cli-recovery", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func thawAll() throws -> String {
        let report: RecoveryReport
        do { report = try JournalSession.thawAll(paths: .standard) }
        catch OwnerLock.Failure.heldByAnother {
            throw CLIError(message: "Journal kilidi başka bir süreçte; Ohm veya kurtarma izleyicisi hâlâ çalışıyor. Yeniden deneyin.")
        }
        guard !report.needsRetry else {
            throw CLIError(message: "Bazı süreçler çözülemedi; journal kaydı korundu. `ohm thaw --all` ile yeniden deneyin.")
        }
        guard report.forcedClosedGroups.isEmpty else {
            throw CLIError(message: "\(report.thawed.count) süreç çözüldü, \(report.eCoreCleared.count) E-core etkisi kaldırıldı. \(report.forcedClosedGroups.count) grubun kimliği doğrulanamadı; sinyal gönderilmeden journal takibi kapatıldı. Süreçlerin çözüldüğü doğrulanmadı.")
        }
        return "Kurtarma tamamlandı: \(report.thawed.count) süreç çözüldü, \(report.eCoreCleared.count) E-core etkisi kaldırıldı."
    }
}
