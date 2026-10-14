import Foundation
import Testing
@testable import Dropcap

// 구독 상태와 보이는 글: 끄기·다시 켜기·해지·분야 해제·숨기기가 목록·매거진 판단에 바로 반영되는지
@Suite struct SourceFilterTests {
    private let sources = Array(Resources.config.sources.prefix(3))
    private func item(_ src: String, _ id: String) -> NewsItem {
        NewsItem(id: id, title: "t-\(id)", titleKo: nil, link: "https://x.com/\(id)", date: Date(), summary: "", sourceId: src, sourceName: src, tier: "press")
    }
    private func state(on: [String], hidden: [String] = []) -> AppState {
        var s = AppState()
        for id in on { s.enabled[id] = true }
        s.hiddenSources = hidden
        return s
    }

    @Test func turningOffHidesAndTurningOnRestores() {
        let (a, b) = (sources[0].id, sources[1].id)
        let items = [item(a, "1"), item(b, "2"), item(a, "3")]
        var st = state(on: [a, b])
        #expect(SourceFilter.make(state: st, sources: sources).visible(items).count == 3)
        st.enabled[a] = false                       // 구독 끄기
        #expect(SourceFilter.make(state: st, sources: sources).visible(items).map(\.id) == ["2"])
        st.enabled[a] = true                        // 다시 켜기 → 지우지 않았으므로 그대로 돌아옴
        #expect(SourceFilter.make(state: st, sources: sources).visible(items).count == 3)
    }

    @Test func removedCustomSourceIsHidden() {
        let a = sources[0].id
        let gone = "custom-removed-channel"         // 해지해서 출처 목록에 없는 채널
        let st = state(on: [a, gone])
        let v = SourceFilter.make(state: st, sources: sources).visible([item(a, "1"), item(gone, "2")])
        #expect(v.map(\.id) == ["1"])
    }

    @Test func sectionDeselectTurnsSourcesOffSoTheyHide() {
        // 분야를 빼면 그 분야 출처의 enabled 가 false 가 되므로(chooseSections) 같은 판단으로 빠진다
        let (a, b) = (sources[0].id, sources[1].id)
        var st = state(on: [a, b])
        st.enabled[b] = false
        #expect(SourceFilter.make(state: st, sources: sources).shows(a))
        #expect(!SourceFilter.make(state: st, sources: sources).shows(b))
    }

    @Test func hiddenWinsEvenWhenEnabled() {
        let a = sources[0].id
        let st = state(on: [a], hidden: [a])
        #expect(!SourceFilter.make(state: st, sources: sources).shows(a))
    }

    @Test func neverEnabledSourceIsHidden() {
        let st = state(on: [])
        #expect(!SourceFilter.make(state: st, sources: sources).shows(sources[0].id))
    }

    @Test func noActiveSetMeansOnlyHiddenApplies() { // 시험·옮기기용 기본값
        let f = SourceFilter(hidden: ["x"])
        #expect(f.shows("y") && !f.shows("x"))
    }
}
