import Foundation

public enum WidgetFormatter {
    private static let translations: [String: [String: String]] = [
        "Today's receipt": [
            "tr": "Bugünün fişi",
            "en": "Today's receipt"
        ],
        "Daily battery receipt from Ohm": [
            "tr": "Ohm'dan günlük pil fişi",
            "en": "Daily battery receipt from Ohm"
        ],
        "No data yet — open Ohm": [
            "tr": "Henüz veri yok — Ohm'u açın",
            "en": "No data yet — open Ohm"
        ],
        "No widget data in this build": [
            "tr": "Bu derlemede widget verisi yok",
            "en": "No widget data in this build"
        ],
        "Total": [
            "tr": "Toplam",
            "en": "Total"
        ],
        "Total battery": [
            "tr": "Toplam pil",
            "en": "Total battery"
        ],
        "Total energy": [
            "tr": "Toplam enerji",
            "en": "Total energy"
        ]
    ]

    public static func localized(_ key: String, locale: Locale) -> String {
        let lang = locale.identifier.starts(with: "tr") ? "tr" : "en"
        if let dict = translations[key], let val = dict[lang] {
            return val
        }
        return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    public static func formatDuration(minutes: Double, locale: Locale) -> String {
        let isTR = locale.identifier.starts(with: "tr")
        if minutes > 0 && minutes < 0.75 {
            return isTR ? "< 1 dk" : "< 1 min"
        }
        let totalSeconds = Int64((minutes * 60).rounded())
        let duration = Duration.seconds(totalSeconds)
        let formatted = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
        if isTR {
            return formatted
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "\u{202f}", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return formatted
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    public static func formatAccessibilityDuration(minutes: Double, locale: Locale) -> String {
        let isTR = locale.identifier.starts(with: "tr")
        if minutes > 0 && minutes < 0.75 {
            return isTR ? "1 dakikadan az" : "less than 1 minute"
        }
        let totalSeconds = Int64((minutes * 60).rounded())
        let duration = Duration.seconds(totalSeconds)
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
    }

    public static func formatWh(wh: Double, locale: Locale) -> String {
        let isTR = locale.identifier.starts(with: "tr")
        if wh > 0 && wh < 0.05 {
            return isTR ? "< 0,1 Wh" : "< 0.1 Wh"
        }
        let numStr = wh.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return "\(numStr) Wh"
    }

    public static func formatAccessibilityWh(wh: Double, locale: Locale) -> String {
        let isTR = locale.identifier.starts(with: "tr")
        if wh > 0 && wh < 0.05 {
            return isTR ? "0,1 vat-saatten az" : "less than 0.1 watt-hours"
        }
        let numStr = wh.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return isTR ? "\(numStr) vat-saat" : "\(numStr) watt-hours"
    }

    public static func formatAppValue(_ app: WidgetAppItem, locale: Locale, compact: Bool) -> String {
        if let min = app.batteryMinutes, min > 0 {
            let dur = formatDuration(minutes: min, locale: locale)
            if !compact, let acWh = app.chargingWh, acWh >= 0.1 {
                let whStr = formatWh(wh: acWh, locale: locale)
                return "\(dur) · \(whStr)"
            }
            return dur
        } else {
            return formatWh(wh: app.totalEnergyWh, locale: locale)
        }
    }

    public static func formatTotalValue(_ data: ReceiptWidgetData, locale: Locale, compact: Bool) -> String {
        if let min = data.totalBatteryMinutes, min > 0 {
            let dur = formatDuration(minutes: min, locale: locale)
            if !compact, let acWh = data.totalAcWh, acWh >= 0.1 {
                let whStr = formatWh(wh: acWh, locale: locale)
                return "\(dur) · \(whStr)"
            }
            return dur
        } else {
            return formatWh(wh: data.totalEnergyWh, locale: locale)
        }
    }

    public static func totalCaption(_ data: ReceiptWidgetData, locale: Locale) -> String {
        if let min = data.totalBatteryMinutes, min > 0 {
            return localized("Total battery", locale: locale)
        } else {
            return localized("Total energy", locale: locale)
        }
    }

    public static func appAccessibilityLabel(_ app: WidgetAppItem, rank: Int, locale: Locale) -> String {
        let isTR = locale.identifier.starts(with: "tr")
        if let min = app.batteryMinutes, min > 0 {
            let dur = formatAccessibilityDuration(minutes: min, locale: locale)
            if let acWh = app.chargingWh, acWh >= 0.1 {
                let whStr = formatAccessibilityWh(wh: acWh, locale: locale)
                return isTR
                    ? "\(rank). \(app.displayName), \(dur) pil, \(whStr) şarj"
                    : "\(rank). \(app.displayName), \(dur) of battery, \(whStr) charging"
            } else {
                return isTR
                    ? "\(rank). \(app.displayName), \(dur) pil"
                    : "\(rank). \(app.displayName), \(dur) of battery"
            }
        } else {
            let whStr = formatAccessibilityWh(wh: app.totalEnergyWh, locale: locale)
            return "\(rank). \(app.displayName), \(whStr)"
        }
    }

    public static func totalAccessibilityLabel(_ data: ReceiptWidgetData, locale: Locale) -> String {
        let isTR = locale.identifier.starts(with: "tr")
        if let min = data.totalBatteryMinutes, min > 0 {
            let dur = formatAccessibilityDuration(minutes: min, locale: locale)
            if let acWh = data.totalAcWh, acWh >= 0.1 {
                let whStr = formatAccessibilityWh(wh: acWh, locale: locale)
                return isTR
                    ? "Toplam: \(dur) pil, \(whStr) şarj"
                    : "Total: \(dur) of battery, \(whStr) charging"
            } else {
                return isTR
                    ? "Toplam pil: \(dur)"
                    : "Total battery: \(dur)"
            }
        } else {
            let whStr = formatAccessibilityWh(wh: data.totalEnergyWh, locale: locale)
            return isTR
                ? "Toplam enerji: \(whStr)"
                : "Total energy: \(whStr)"
        }
    }
}
