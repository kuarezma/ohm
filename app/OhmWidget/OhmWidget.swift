import WidgetKit
import SwiftUI
import OhmModel
import OhmLedger

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let timeline = Timeline(entries: [SimpleEntry(date: Date())], policy: .atEnd)
        completion(timeline)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
}

struct OhmWidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        Text("Today's receipt")
    }
}

@main
struct OhmWidget: Widget {
    let kind: String = "OhmWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            OhmWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Today's receipt")
        .description("Today's receipt")
    }
}
