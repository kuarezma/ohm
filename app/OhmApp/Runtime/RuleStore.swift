import Foundation
import OhmLedger
import OhmModel
import OhmRules
import OSLog

public struct PersistedRules: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var rules: [Rule]
    public var neverFreeze: [String]

    public init(schemaVersion: Int = 1, rules: [Rule] = [], neverFreeze: [String] = []) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.neverFreeze = neverFreeze
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, rules, neverFreeze
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        self.neverFreeze = try container.decodeIfPresent([String].self, forKey: .neverFreeze) ?? []
    }
}

public actor RuleStore {
    public let fileURL: URL
    public private(set) var rules: [Rule] = []
    public private(set) var neverFreeze: [String] = []
    public private(set) var corruptWarning: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultRulesURL() -> URL? {
        if let groupID = OhmRuntime.appGroupIdentifier(),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return container.appendingPathComponent("rules.json")
        }
        return EnergyLedger.localDataDirectory().appendingPathComponent("rules.json")
    }

    public func load() -> PersistedRules {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            rules = []
            neverFreeze = []
            return PersistedRules(schemaVersion: 1, rules: [], neverFreeze: [])
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()

            var decoded: PersistedRules? = nil
            if let persisted = try? decoder.decode(PersistedRules.self, from: data) {
                decoded = persisted
            } else if let doc = try? decoder.decode(RulesDocument.self, from: data) {
                decoded = PersistedRules(schemaVersion: doc.schemaVersion, rules: doc.rules, neverFreeze: [])
            } else if let arr = try? decoder.decode([Rule].self, from: data) {
                decoded = PersistedRules(schemaVersion: 1, rules: arr, neverFreeze: [])
            } else if let single = try? decoder.decode(Rule.self, from: data) {
                decoded = PersistedRules(schemaVersion: single.schemaVersion, rules: [single], neverFreeze: [])
            }

            guard let persisted = decoded else {
                return handleCorruptFile()
            }

            // ADR 0003 § 1: rules with unsupported condition load as disabled
            var validatedRules: [Rule] = []
            let neverFreezeSet = Set(persisted.neverFreeze)
            for var rule in persisted.rules {
                if hasUnsupportedCondition(rule.when) {
                    rule.enabled = false
                }
                do {
                    try RuleValidator.validate(rule: rule, neverFreezeBundleIDs: neverFreezeSet)
                    validatedRules.append(rule)
                } catch {
                    // Invalid rule loaded; disable it to stay safe
                    rule.enabled = false
                    validatedRules.append(rule)
                }
            }

            self.rules = validatedRules
            self.neverFreeze = persisted.neverFreeze
            return PersistedRules(schemaVersion: persisted.schemaVersion, rules: validatedRules, neverFreeze: persisted.neverFreeze)
        } catch {
            return handleCorruptFile()
        }
    }

    private func handleCorruptFile() -> PersistedRules {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(timestamp).json")
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        let warning = "Kural dosyası (\(fileURL.lastPathComponent)) bozuktu; yedeğe alındı (\(backupURL.lastPathComponent)) ve boş listeyle açıldı."
        Logger(subsystem: "dev.ohm", category: "rules").error("\(warning, privacy: .public)")
        self.corruptWarning = warning
        self.rules = []
        self.neverFreeze = []
        return PersistedRules(schemaVersion: 1, rules: [], neverFreeze: [])
    }

    public func save() throws {
        let persisted = PersistedRules(schemaVersion: 1, rules: rules, neverFreeze: neverFreeze)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persisted)

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmpURL = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)

        guard rename(tmpURL.path, fileURL.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmpURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }
    }

    public func addRule(_ rule: Rule) throws {
        try RuleValidator.validate(rule: rule, neverFreezeBundleIDs: Set(neverFreeze))
        rules.append(rule)
        try save()
    }

    public func toggleRule(id: UUID) throws {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled.toggle()
        try save()
    }

    public func deleteRule(id: UUID) throws {
        rules.removeAll { $0.id == id }
        try save()
    }

    public func setRules(_ newRules: [Rule]) throws {
        self.rules = newRules
        try save()
    }

    public func addNeverFreeze(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !neverFreeze.contains(trimmed) else { return }
        neverFreeze.append(trimmed)
        try save()
    }

    public func removeNeverFreeze(_ name: String) throws {
        neverFreeze.removeAll { $0 == name }
        try save()
    }

    public func setNeverFreeze(_ names: [String]) throws {
        self.neverFreeze = names
        try save()
    }

    public func clearCorruptWarning() {
        self.corruptWarning = nil
    }

    private func hasUnsupportedCondition(_ condition: Condition) -> Bool {
        switch condition {
        case .unsupported:
            return true
        case .all(let conditions), .any(let conditions):
            return conditions.contains { hasUnsupportedCondition($0) }
        case .not(let child):
            return hasUnsupportedCondition(child)
        default:
            return false
        }
    }
}
