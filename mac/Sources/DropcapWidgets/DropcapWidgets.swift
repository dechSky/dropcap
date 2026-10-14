import DropcapShared
import SwiftUI
import WidgetKit

// 위젯 확장(.appex). 앱이 써 둔 스냅숏만 읽는다(네트워크 없음). 앱이 새로 쓰면 WidgetCenter 로 다시 그리게 한다.
struct DropcapEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DropcapEntry { DropcapEntry(date: Date(), content: WidgetContent(snapshot: .sample)) }

    func getSnapshot(in context: Context, completion: @escaping (DropcapEntry) -> Void) {
        let c = WidgetContent.load()
        completion(DropcapEntry(date: Date(), content: context.isPreview && c.snapshot.cover == nil ? WidgetContent(snapshot: .sample) : c))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DropcapEntry>) -> Void) {
        // 앱이 꺼져 있어도 '몇 분 전' 표시가 낡지 않게 30분마다 다시 읽는다
        completion(Timeline(entries: [DropcapEntry(date: Date(), content: WidgetContent.load())],
                            policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.neulloopa.dropcap.today", provider: Provider()) { entry in
            EntryView(entry: entry)
        }
        .configurationDisplayName("오늘의 소식")
        .description("오늘의 표지와 최신 소식, 안 읽은 수")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct EntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DropcapEntry
    var body: some View {
        switch family {
        case .systemSmall: DropcapSmallView(entry.content)
        default: DropcapMediumView(entry.content)
        }
    }
}

@main
struct DropcapWidgets: WidgetBundle {
    var body: some Widget { TodayWidget() }
}
