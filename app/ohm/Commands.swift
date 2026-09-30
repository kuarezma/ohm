import ArgumentParser
import Foundation
import OhmControl

struct ReceiptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "receipt", abstract: "Bugünün enerji fişini oku; Ohm'un açık olması gerekmez.")
    @Flag(help: "Bugünün fişi (varsayılan).") var today = false
    @Flag(name: .long, help: "JSON çıktısı.") var json = false

    func run() async throws {
        do { try CLIOutput.receipt(CLILedger.receipt(history: false), json: json) }
        catch { try CLIOutput.fail(error.localizedDescription) }
    }
}

struct TopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "top", abstract: "Son canlı enerji örneğini veya kayıt geçmişini göster.")
    @Flag(help: "SQLite üzerinden son 7 günlük geçmiş; Ohm'un açık olması gerekmez.") var history = false
    @Flag(name: .long, help: "JSON çıktısı.") var json = false

    func run() async throws {
        if history {
            do { try CLIOutput.receipt(CLILedger.receipt(history: true), json: json) }
            catch { try CLIOutput.fail(error.localizedDescription) }
        } else {
            let response = try await CLIOutput.control(ControlRequest(operation: .top))
            guard let top = response.top else { try CLIOutput.fail("Canlı örnek yanıtı boş.") }
            try CLIOutput.top(top, json: json)
        }
    }
}

struct ECoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ecore", abstract: "Uygulamayı E-core'a al veya etkisini kaldır.")
    @Argument(help: "Çalışan uygulamanın adı, bundle ID veya PID.") var application: String
    @Flag(help: "E-core etkisini kaldır.") var off = false

    func run() async throws {
        let response = try await CLIOutput.control(ControlRequest(operation: .eCore, target: application, off: off))
        print(response.message)
    }
}

struct FreezeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "freeze", abstract: "Uygulamayı veya PID'yi Governor güvenlik kontrolleriyle dondur.")
    @Argument(help: "Çalışan uygulamanın adı, bundle ID veya PID.") var application: String

    func run() async throws {
        print(try await CLIOutput.control(ControlRequest(operation: .freeze, target: application)).message)
    }
}

struct ThawCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "thaw", abstract: "Donuk uygulamayı çöz; --all bütün Ohm etkilerini geri alır.")
    @Argument(help: "Çalışan uygulamanın adı, bundle ID veya PID.") var application: String?
    @Flag(help: "Tümünü çöz; Ohm kapalıysa journal kilidini alıp kurtarma çalıştır.") var all = false

    func validate() throws {
        guard all != (application != nil) else { throw ValidationError("Bir uygulama/PID veya yalnız --all belirtin.") }
    }

    func run() async throws {
        let request = ControlRequest(operation: all ? .thawAll : .thaw, target: application)
        if all {
            do {
                let client = ControlClient(path: try ControlSocket.path())
                let response = try await client.request(request)
                guard response.success else { try CLIOutput.fail(response.message) }
                print(response.message)
            } catch ControlTransportError.notRunning {
                do { print(try await CLIRecovery().thawAll()) }
                catch { try CLIOutput.fail(error.localizedDescription) }
            } catch let exit as ExitCode { throw exit }
            catch { try CLIOutput.fail(error.localizedDescription) }
        } else {
            print(try await CLIOutput.control(request).message)
        }
    }
}
