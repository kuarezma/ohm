import Darwin
import Foundation
import OhmControl

/// Transport-only fixture: no Governor, journal, sampling or process effects.
@main
struct ServerHarness {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3, let seconds = Double(CommandLine.arguments[2]) else { exit(64) }
            let server = ControlServer { request in
                if request.target == "delay" { try? await Task.sleep(for: .seconds(30)) }
                return ControlResponse(id: request.id, message: "fixture",
                                       top: request.operation == .top ? ControlTop(sampledAt: Date(), watts: 1, processes: []) : nil)
            }
            try await server.start(path: CommandLine.arguments[1])
            FileHandle.standardOutput.write(Data("READY\n".utf8))
            try await Task.sleep(for: .seconds(seconds))
            await server.stop()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
