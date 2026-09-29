// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OhmCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "OhmModel", targets: ["OhmModel"]),
        .library(name: "COhmSys", targets: ["COhmSys"]),
        .library(name: "OhmSampling", targets: ["OhmSampling"]),
        .library(name: "OhmLedger", targets: ["OhmLedger"]),
        .library(name: "OhmJournal", targets: ["OhmJournal"]),
        .library(name: "OhmGovernor", targets: ["OhmGovernor"]),
        .library(name: "OhmRules", targets: ["OhmRules"]),
        .library(name: "OhmForecast", targets: ["OhmForecast"]),
        .library(name: "OhmControl", targets: ["OhmControl"]),
    ],
    targets: [
        .target(
            name: "OhmModel"
        ),
        .target(
            name: "COhmSys"
        ),
        .target(
            name: "OhmSampling",
            dependencies: [
                "OhmModel",
                "COhmSys",
            ]
        ),
        .target(
            name: "OhmLedger",
            dependencies: [
                "OhmModel",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "OhmJournal",
            dependencies: [
                "OhmModel",
                "COhmSys",
            ]
        ),
        .target(
            name: "OhmGovernor",
            dependencies: [
                "OhmModel",
                "OhmJournal",
                "COhmSys",
            ]
        ),
        .target(
            name: "OhmRules",
            dependencies: [
                "OhmModel",
            ]
        ),
        .target(
            name: "OhmForecast",
            dependencies: [
                "OhmModel",
            ]
        ),
        .target(
            name: "OhmControl",
            dependencies: [
                "OhmModel",
            ]
        ),
        .testTarget(
            name: "OhmModelTests",
            dependencies: ["OhmModel"]
        ),
        .testTarget(
            name: "OhmLedgerTests",
            dependencies: ["OhmLedger"]
        ),
        .testTarget(
            name: "OhmJournalTests",
            dependencies: ["OhmJournal"]
        ),
        .testTarget(
            name: "OhmGovernorTests",
            dependencies: ["OhmGovernor"]
        ),
        .testTarget(
            name: "OhmRulesTests",
            dependencies: ["OhmRules"]
        ),
        .testTarget(
            name: "OhmForecastTests",
            dependencies: ["OhmForecast"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
