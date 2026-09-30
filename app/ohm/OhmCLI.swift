import ArgumentParser
import OhmModel
import OhmLedger
import OhmControl
import OhmJournal

@main
struct OhmCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ohm",
        abstract: "Ohm enerji fişi ve süreç yönetimi",
        version: "ohm 0.1.0",
        subcommands: [ReceiptCommand.self, TopCommand.self, ECoreCommand.self, FreezeCommand.self, ThawCommand.self]
    )

}
