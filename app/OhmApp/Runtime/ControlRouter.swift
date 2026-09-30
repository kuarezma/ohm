import AppKit
import OhmControl
import OhmJournal
import OhmModel

enum ControlTargetResolution: Sendable {
    case identity(ProcessIdentity)
    case failure(ControlErrorCode, String)
}

enum ControlRouter {
    @MainActor
    static func resolve(_ target: String) -> ControlTargetResolution {
        if let pid = Int32(target), pid > 0 {
            guard let identity = ProcessProbe.identity(of: pid) else {
                return .failure(.notFound, "PID \(pid) çalışmıyor veya kimliği okunamadı.")
            }
            return .identity(identity)
        }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.caseInsensitiveCompare(target) == .orderedSame ||
            $0.localizedName?.caseInsensitiveCompare(target) == .orderedSame ||
            $0.bundleURL?.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(target) == .orderedSame
        }
        guard matches.count == 1, let app = matches.first else {
            return matches.isEmpty ? .failure(.notFound, "Çalışan uygulama bulunamadı: \(target).")
                : .failure(.ambiguousTarget, "Birden çok uygulama eşleşti; kesin PID veya bundle ID kullanın.")
        }
        guard let identity = ProcessProbe.identity(of: app.processIdentifier) else {
            return .failure(.notFound, "Uygulamanın süreç kimliği okunamadı.")
        }
        return .identity(identity)
    }

    static func failure(_ request: ControlRequest, code: ControlErrorCode, message: String,
                        vetoes: [FreezeVeto] = []) -> ControlResponse {
        ControlResponse(id: request.id, message: message, error: ControlFailure(code: code, vetoes: vetoes))
    }

    static func response(_ request: ControlRequest, outcome: GovernorOutcome) -> ControlResponse {
        switch outcome {
        case .vetoed(let vetoes):
            return failure(request, code: .vetoed,
                           message: vetoes.map { "\($0.rawValue): \(LiveDataSource.vetoMessage($0))" }.joined(separator: "\n"),
                           vetoes: vetoes)
        case .rolledBack(_, let detail): return failure(request, code: .rolledBack, message: "İşlem geri alındı: \(detail)")
        case .notFound: return failure(request, code: .notFound, message: "Bu süreç için etkin işlem bulunamadı.")
        case .frozen: return ControlResponse(id: request.id, message: "Uygulama donduruldu.")
        case .thawed(let groups):
            let message = request.operation == .thawAll
                ? "Çözme tamamlandı; \(groups) dondurma grubu çözüldü, E-core etkileri geri alındı."
                : "\(groups) dondurma grubu çözüldü."
            return ControlResponse(id: request.id, message: message)
        case .eCoreApplied: return ControlResponse(id: request.id, message: "Uygulama E-core'a alındı.")
        case .eCoreRemoved: return ControlResponse(id: request.id, message: "E-core etkisi kaldırıldı.")
        }
    }

    static func response(_ request: ControlRequest, report: ThawReport) -> ControlResponse {
        guard report.recoveryComplete else {
            let detail = report.recoveryFailures.joined(separator: "\n")
            return failure(request, code: .recoveryPending,
                           message: "Tümünü çöz işlemi doğrulanarak tamamlanamadı.\n" + detail)
        }
        return ControlResponse(id: request.id,
                               message: "Çözme tamamlandı; \(report.freezeGroups) dondurma ve \(report.eCoreGroups) E-core grubu geri alındı.")
    }

    static func top(from tick: SampleTick, watts: Double) -> ControlTop {
        let parts = tick.interval.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
        let rows = tick.processes.sorted { $0.energy_nJ > $1.energy_nJ }.prefix(100).map { process in
            ControlProcess(pid: process.identity.pid, name: String(process.displayName.prefix(64)),
                           cpuPercent: seconds > 0 ? Double(process.cpuTime_ns) * 1e-9 / seconds * 100 : 0,
                           watts: seconds > 0 ? Double(process.energy_nJ) * 1e-9 / seconds : 0)
        }
        return ControlTop(sampledAt: tick.wallClock, watts: watts, processes: rows)
    }
}
