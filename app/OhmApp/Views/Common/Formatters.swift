import Foundation

public enum OhmFormatters {
    /// Formats duration for compact UI display (e.g. "5 sa 10 dk" in TR, "5 hr, 10 min" in EN).
    public static func formatDuration(minutes: Double, locale: Locale) -> String {
        let totalSeconds = Int64((minutes * 60).rounded())
        let duration = Duration.seconds(totalSeconds)
        let formatted = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))

        // Turkish CLDR includes abbreviations with dots and narrow no-break space (e.g. "5 sa. 10 dk.").
        // Strip dots and normalize spaces so it renders naturally: "5 sa 10 dk", "38 dk", "2 sa".
        if locale.identifier.starts(with: "tr") {
            return formatted
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "\u{202f}", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return formatted
    }

    /// Formats duration for accessibility using wide style (e.g. "38 dakika" in TR, "38 minutes" in EN).
    public static func formatAccessibilityDuration(minutes: Double, locale: Locale) -> String {
        let totalSeconds = Int64((minutes * 60).rounded())
        let duration = Duration.seconds(totalSeconds)
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
    }

    /// Formats battery accessibility string: wide style ("38 dakika pil" in TR, "38 minutes of battery" in EN).
    public static func formatBatteryAccessibility(minutes: Double, locale: Locale) -> String {
        let wideDuration = formatAccessibilityDuration(minutes: minutes, locale: locale)
        return localizedFormat("%@ of battery", locale: locale, wideDuration)
    }

    /// Formats CPU percentage according to locale (e.g. "%94" in TR, "94%" in EN).
    public static func formatPercent(_ percent: Double, locale: Locale) -> String {
        let fraction = percent / 100.0
        return fraction.formatted(.percent.locale(locale))
    }

    /// Resolves localized string explicitly from the bundle for the given locale.
    public static func localizedString(_ key: String, locale: Locale) -> String {
        let lang = locale.identifier.starts(with: "tr") ? "tr" : "en"
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: nil, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Formats a localized format string explicitly with the specified locale.
    public static func localizedFormat(_ key: String, locale: Locale, _ args: CVarArg...) -> String {
        let format = localizedString(key, locale: locale)
        return String(format: format, locale: locale, arguments: args)
    }
}
