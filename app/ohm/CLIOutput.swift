import ArgumentParser
import Foundation
import OhmControl
import OhmModel

enum CLIOutput {
    static func fail(_ message: String, code: Int32 = 1) throws -> Never {
        let printable = String(message.unicodeScalars.filter {
            $0.value == 10 || !CharacterSet.controlCharacters.contains($0)
        })
        FileHandle.standardError.write(Data((printable + "\n").utf8))
        throw ExitCode(code)
    }

    static func control(_ request: ControlRequest) async throws -> ControlResponse {
        do {
            let client = ControlClient(path: try ControlSocket.path())
            let response = try await client.request(request)
            guard response.success else { try fail(response.message) }
            return response
        } catch ControlTransportError.notRunning {
            try fail(ControlTransportError.notRunning.localizedDescription, code: 2)
        } catch let exit as ExitCode { throw exit }
        catch { try fail(error.localizedDescription) }
    }

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    static func receipt(_ receipt: Receipt, json: Bool) throws {
        if json { try self.json(receipt); return }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "tr_TR")
        dateFormatter.dateFormat = "dd.MM.yyyy HH:mm"
        print("Enerji fişi: \(dateFormatter.string(from: receipt.interval.start)) – \(dateFormatter.string(from: receipt.interval.end))")
        guard !receipt.allRows.isEmpty || receipt.measuredSystemEnergy_uj > 0 else {
            print("Henüz enerji kaydı yok.")
            return
        }
        print("Uygulama\tEnerji (Wh)\tPil (dk)\tŞarjda (Wh)")
        for row in receipt.allRows {
            print("\(safe(row.displayName))\t\(decimal(Double(row.energy_uj) / 3_600_000_000))\t\(row.batteryMinutes.map(decimal) ?? "—")\t\(row.chargingWh.map(decimal) ?? "—")")
        }
        print("Ölçülen sistem enerjisi: \(decimal(Double(receipt.measuredSystemEnergy_uj) / 3_600_000_000)) Wh")
        print("Diğer: \(decimal(Double(receipt.other_uj) / 3_600_000_000)) Wh; GPU: \(decimal(Double(receipt.gpu_uj) / 3_600_000_000)) Wh")
        if receipt.isFlagged { print("Uyarı: uygulamalara atfedilen enerji, sistem ölçümünü aşıyor.") }
    }

    static func top(_ top: ControlTop, json: Bool) throws {
        if json { try self.json(top); return }
        print("Canlı örnek: \(top.sampledAt.formatted()) — sistem \(decimal(top.watts)) W")
        print("PID\tUygulama\tCPU (%)\tGüç (W)")
        for process in top.processes {
            print("\(process.pid)\t\(safe(process.name))\t\(decimal(process.cpuPercent))\t\(decimal(process.watts))")
        }
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "tr_TR"), value)
    }

    private static func safe(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }
}
