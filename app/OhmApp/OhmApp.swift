import SwiftUI
import OhmModel
import COhmSys
import OhmSampling
import OhmLedger
import OhmJournal
import OhmGovernor
import OhmRules
import OhmForecast
import OhmControl

@main
struct OhmApp: App {
    var body: some Scene {
        MenuBarExtra("Ohm", systemImage: "bolt.circle") {
            Text("Ohm")
        }
        .menuBarExtraStyle(.window)
    }
}
