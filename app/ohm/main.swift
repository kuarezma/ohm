import ArgumentParser
import OhmModel
import OhmLedger
import OhmControl
import OhmJournal

struct OhmCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ohm",
        abstract: "Ohm command-line tool",
        version: "ohm 0.0.1"
    )

    func run() throws {
        print("ohm 0.0.1")
    }
}

OhmCLI.main()
