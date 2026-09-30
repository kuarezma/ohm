import WidgetKit
import SwiftUI
import OhmModel
import OhmLedger

struct Provider: TimelineProvider {
    typealias Entry = ReceiptEntry

    func placeholder(in context: Context) -> ReceiptEntry {
        ReceiptEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (ReceiptEntry) -> Void) {
        if context.isPreview {
            completion(ReceiptEntry.previewSample)
            return
        }
        let entry = WidgetDataLoader.loadCurrentEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReceiptEntry>) -> Void) {
        let entry = WidgetDataLoader.loadCurrentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)
            ?? entry.date.addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct OhmWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let data = entry.data, data.hasData, !data.topApps.isEmpty {
                switch family {
                case .systemMedium:
                    WidgetMediumView(data: data)
                default:
                    WidgetSmallView(data: data)
                }
            } else {
                WidgetEmptyView(storageUnavailable: entry.storageUnavailable)
            }
        }
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

@main
struct OhmWidget: Widget {
    let kind: String = "OhmWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            OhmWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringResource("Today's receipt", defaultValue: "Today's receipt"))
        .description(LocalizedStringResource("Daily battery receipt from Ohm", defaultValue: "Daily battery receipt from Ohm"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview("Small - Light", as: .systemSmall) {
    OhmWidget()
} timeline: {
    ReceiptEntry.previewSample
}

#Preview("Small - Dark", as: .systemSmall) {
    OhmWidget()
} timeline: {
    ReceiptEntry.previewSample
}

#Preview("Medium - Light", as: .systemMedium) {
    OhmWidget()
} timeline: {
    ReceiptEntry.previewSample
}

#Preview("Medium - Dark", as: .systemMedium) {
    OhmWidget()
} timeline: {
    ReceiptEntry.previewSample
}

#Preview("Small - Empty", as: .systemSmall) {
    OhmWidget()
} timeline: {
    ReceiptEntry.empty
}
