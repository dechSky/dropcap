import AppKit
import SwiftUI

// 디자인 시스템: 화면이 쓰는 움직임·간격·모서리·글자·색·높이의 단 하나의 기준(docs/DESIGN.md).
// 화면 코드는 숫자를 직접 쓰지 않고 여기 이름을 쓴다. 값을 바꿀 땐 여기 한 곳만 고친다.

// MARK: - 움직임

enum Motion {
    // 성격: 차분(튀지 않고 빨리 자리 잡음). '경쾌'로 바꾸려면 springDamping 만 낮춘다(0.86 → 0.74).
    static let springDamping: Double = 0.86

    // 지속 3단 — 작은 상태(올림·누름) · 나타남/사라짐 · 지면/창처럼 큰 것
    enum Duration {
        static let quick: Double = 0.15
        static let standard: Double = 0.25
        static let slow: Double = 0.4
    }

    // 곡선: 들어올 땐 빨리 와서 천천히 멈추고(감속), 나갈 땐 천천히 떠나 빨리 사라진다(가속). 나감은 들어옴보다 짧다.
    static let enterCurve = (0.2, 0.9, 0.25, 1.0)
    static let exitCurve = (0.4, 0.0, 1.0, 1.0)

    static func enter(_ d: Double = Duration.standard) -> Animation {
        .timingCurve(enterCurve.0, enterCurve.1, enterCurve.2, enterCurve.3, duration: d)
    }
    static func exit(_ d: Double = Duration.quick) -> Animation {
        .timingCurve(exitCurve.0, exitCurve.1, exitCurve.2, exitCurve.3, duration: d)
    }
    // 자리 안에서 바뀜(테마·크기·스크롤 이동)
    static func change(_ d: Double = Duration.standard) -> Animation { .easeInOut(duration: d) }

    // 스프링 2개 — 손에 닿는 것(올림·고름·펼침)과 큰 배치(지면 넘김·카드 깔림)
    static var snap: Animation { .spring(response: 0.3, dampingFraction: springDamping) }
    static var settle: Animation { .spring(response: 0.5, dampingFraction: max(springDamping, 0.88)) }

    // 차례로 깔림: 한 칸 0.04초, 최대 0.3초까지만 늦춘다
    static func stagger(_ index: Int) -> Double { min(Double(index) * 0.04, 0.3) }

    // 이어지는 움직임(불러오는 중 회전·물결)은 예외로 이 곡선만
    static func loop(_ period: Double) -> Animation { .linear(duration: period).repeatForever(autoreverses: false) }

    // 시스템 '동작 줄이기'가 켜져 있으면 위치·크기 움직임 없이 짧은 페이드만
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func resolve(_ a: Animation?) -> Animation? { reduced ? (a == nil ? nil : .easeOut(duration: Duration.quick)) : a }

    // 전환(나타남·사라짐)은 이 넷만 쓴다
    static var fade: AnyTransition { .opacity }
    static var rise: AnyTransition { reduced ? .opacity : .opacity.combined(with: .offset(y: Space.s)) }  // 아래에서 살짝 떠오름(본문·아래 붙은 알림)
    static var drop: AnyTransition { reduced ? .opacity : .opacity.combined(with: .offset(y: -Space.s)) } // 위에서 살짝 내려옴(위에 붙은 막대·띠)
    static var pop: AnyTransition { reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.96)) }   // 제자리에서 살짝 커짐
    // 지면 넘김: 새 지면은 떠오르고 이전 지면은 빨리 흐려진다
    static var page: AnyTransition { .asymmetric(insertion: rise, removal: .opacity.animation(exit())) }
}

// 동작 줄이기를 따르는 withAnimation
@discardableResult
func withMotion<R>(_ a: Animation?, _ body: () throws -> R) rethrows -> R {
    try withAnimation(Motion.resolve(a), body)
}

extension View {
    // .animation(_, value:) 대신: 동작 줄이기를 따른다
    func motion<V: Equatable>(_ a: Animation?, value: V) -> some View { modifier(MotionModifier(animation: a, value: value)) }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.animation(reduce ? (animation == nil ? nil : .easeOut(duration: Motion.Duration.quick)) : animation, value: value)
    }
}

// 창 열기 규칙: 모든 앱 창(읽기·매거진·분야 고르기·설정)이 같은 방식으로 열린다.
// 제자리에서 0.96 → 1 로 살짝 커지며 나타남(0.25초, 들어옴 곡선). 동작 줄이기면 그냥 나타난다.
// 이미 열린 창을 앞으로 부를 땐 움직이지 않는다. 알림 패널(물방울)은 예외 — 자체 움직임을 쓴다.
@MainActor
enum WindowMotion {
    static let startScale: CGFloat = 0.96

    static func present(_ w: NSWindow) {
        guard !Motion.reduced else { w.makeKeyAndOrderFront(nil); return }
        let target = w.frame
        let dw = target.width * (1 - startScale), dh = target.height * (1 - startScale)
        w.animationBehavior = .none // AppKit 의 기본 창 움직임과 겹치지 않게
        w.alphaValue = 0
        w.setFrame(target.insetBy(dx: dw / 2, dy: dh / 2), display: false)
        w.makeKeyAndOrderFront(nil)
        // 조용한 시험(E2EQuietUI)이 창을 투명·마우스 통과로 숨겼으면 다시 보이게 하지 않는다
        if w.ignoresMouseEvents { w.setFrame(target, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.Duration.standard
            let c = Motion.enterCurve
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1), Float(c.2), Float(c.3))
            w.animator().setFrame(target, display: true)
            w.animator().alphaValue = 1
        }
    }
}

// MARK: - 간격(4 배수)

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
    // 매거진 지면 좌우 여백
    static let page: CGFloat = 36
}

// MARK: - 목록 열(설정 › 구독) — 모든 줄이 같은 열을 쓴다
// [펼침 자리] [아이콘] [이름(고정 폭, 길면 말줄임)] [칩들] … [건수·모두 켜기·구독] [알림 종] [켜기 스위치]
// 하위 줄은 한 단계(아이콘 + 간격) 들여 부모 이름 아래에서 시작하고, 이름 열을 그만큼 줄여 칩 열은 그대로 둔다.
// 윈도우(web/settings.css)·리눅스(settings_sources.rs)도 같은 값을 쓴다.

enum RowColumn {
    static let disclosure: CGFloat = 16                 // 펼침 화살표 자리(없는 줄은 빈칸)
    static let icon: CGFloat = 22                        // 모노그램·분야/지역 아이콘
    static let gap: CGFloat = Space.s                    // 열 사이
    static let indent: CGFloat = icon + gap              // 하위 줄 들여쓰기 한 단계
    static let name: CGFloat = 136                       // 이름 열 — 칩 열이 여기서 시작
    static let bell: CGFloat = 24                        // 알림 종
    static let toggle: CGFloat = 36                      // 켜기 스위치(작게)
    static let controls: CGFloat = bell + gap + toggle   // 종 + 스위치 = 묶음의 '모두 켜기'·추천의 '구독' 자리
}

// MARK: - 모서리

enum Radius {
    static let xs: CGFloat = 4      // 작은 표·배지
    static let control: CGFloat = 8 // 단추·입력칸·작은 사진
    static let card: CGFloat = 14   // 카드·물방울 안 사진·안내 상자
    static let panel: CGFloat = 20  // 큰 표지·떠 있는 판
    // 칩·배지는 Capsule()
}

// MARK: - 글자(역할별) — Font.app/display 위에 얹는다(Pretendard ↔ 시스템 글꼴 설정을 따른다)

extension Font {
    static var dsHero: Font { .display(38, .bold) }        // '오늘' 지면 머리(제호) 하나
    static var dsTitle: Font { .display(32, .bold) }       // 지면 제목(스토리·저장·검색·스크랩북·호)·표지 기사·분야 고르기
    static var dsHeading: Font { .display(20, .semibold) } // 지면 안 묶음 제목·빈 화면 제목
    static var dsSubheading: Font { .display(16, .semibold) } // 카드 제목·작은 묶음 제목
    static var dsHeadline: Font { .app(15, .semibold) }    // 카드 제목·창 안 머리
    static var dsBody: Font { .app(13) }                   // 화면 본문(읽기 창 본문은 ReaderLook 이 따로 정한다)
    static var dsBodyStrong: Font { .app(13, .semibold) }
    static var dsCallout: Font { .app(12) }                // 요약·설명 줄
    static var dsCaption: Font { .app(11) }                // 출처·시간 같은 보조 줄
    static var dsChip: Font { .app(11, .semibold) }        // 칩·배지·작은 단추
    static var dsMicro: Font { .app(9.5, .semibold) }      // 아주 작은 표시(건수·발행 중)
}

// MARK: - 색(의미 이름)

enum Palette {
    static let canvas = Color(nsColor: .textBackgroundColor)      // 매거진·읽기 창 바탕
    static let surface = Color(nsColor: .windowBackgroundColor)   // 창·설정 바탕
    static let raised = Color(nsColor: .controlBackgroundColor)   // 카드 바탕(사진 없을 때)
    static let ink = Color.primary                                // 글
    static let inkSecondary = Color.secondary                     // 보조 글
    static let inkTertiary = Color(nsColor: .tertiaryLabelColor)  // 아주 흐린 글·자리표시
    static let separator = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor                         // 고름·링크·주 단추
    static let paid = Color.orange                                // 유료·맛보기
    static let live = Color.red                                   // 발행 중·속보
    static let positive = Color.green
    static let caution = Color.yellow
    // 분야색은 데이터에서 온다: Sections.byID(id)?.tint / NewsItem.topicColor
    static func section(_ id: String) -> Color { Sections.byID(id)?.tint ?? .gray }
}

// MARK: - 높이(그림자·유리)

struct Shadow {
    let opacity: Double, radius: CGFloat, y: CGFloat
}

enum Elevation {
    static let flat = Shadow(opacity: 0, radius: 0, y: 0)
    static let low = Shadow(opacity: 0.08, radius: 4, y: 1)      // 칩·작은 단추
    static let card = Shadow(opacity: 0.12, radius: 10, y: 4)    // 카드 평소
    static let raised = Shadow(opacity: 0.2, radius: 18, y: 10)  // 카드에 마우스를 올렸을 때
    static let floating = Shadow(opacity: 0.28, radius: 26, y: 14) // 떠 있는 판·표지
}

extension View {
    func elevation(_ s: Shadow, tint: Color = .black) -> some View {
        shadow(color: tint.opacity(s.opacity), radius: s.radius, y: s.y)
    }
    // 유리: 창 머리·떠 있는 막대는 .regularMaterial 하나, 알림 물방울만 macOS 26 glassEffect
    func chromeGlass<S: Shape>(in shape: S) -> some View { background(.regularMaterial, in: shape) }
}
