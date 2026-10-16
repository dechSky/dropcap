import AppKit
import SwiftUI

// 키보드 탐색(G-7): 상단바 목록·매거진 카드·읽기 창이 같은 키를 쓴다.
//   ↑↓ 또는 K·J  선택 이동 · ⏎ 열기 · S 나중에 읽기 · O 브라우저 · M 읽음/안 읽음
//   매거진: ⌘[ · ⌘] 지면 넘기기 · 읽기 창: J·K 다음·이전 기사(연 목록의 순서), Esc 닫기
enum NavKey: Equatable {
    case next, prev, open, save, browser, toggleRead

    // 명령·컨트롤 키가 함께 눌렸으면 탐색 키가 아니다(⌘S 같은 다른 단축키와 겹치지 않게)
    static func from(_ press: KeyPress) -> NavKey? {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch press.key {
        case .downArrow: return .next
        case .upArrow: return .prev
        case .return: return .open
        default: break
        }
        return from(character: press.characters)
    }

    static func from(character c: String) -> NavKey? {
        switch c.lowercased() {
        case "j": return .next
        case "k": return .prev
        case "s": return .save
        case "o": return .browser
        case "m": return .toggleRead
        default: return nil
        }
    }

    // 목록 안에서 선택을 옮긴다(끝에서는 멈춤). 선택이 없으면 처음(또는 끝)부터
    static func move(_ selected: String?, in keys: [String], by step: Int) -> String? {
        guard !keys.isEmpty else { return nil }
        guard let s = selected, let i = keys.firstIndex(of: s) else { return step > 0 ? keys.first : keys.last }
        return keys[min(max(i + step, 0), keys.count - 1)]
    }

    // 단축키 안내(설정 '단축키' 절)
    static let help: [(String, String)] = [
        ("↓ / J · ↑ / K", "다음·이전 소식 고르기 (상단바 목록·매거진 카드)"),
        ("⏎", "고른 소식 열기"),
        ("S", "나중에 읽기 / 저장 취소"),
        ("O", "브라우저에서 열기"),
        ("M", "읽음 / 안 읽음"),
        ("⌘[ · ⌘]", "매거진 이전·다음 지면"),
        ("J · K (읽기 창)", "같은 목록의 다음·이전 기사"),
        ("Esc (읽기 창)", "창 닫기"),
        ("⌘,", "설정 열기 (매거진·읽기 창)"),
    ]
}

// 고른 카드·줄의 테두리: 눈에 띄게(강조색 2.5pt + 옅은 빛). 움직임 줄이기면 애니메이션 없이
struct SelectionRing: ViewModifier {
    let on: Bool
    var radius: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 6)
                        .allowsHitTesting(false)
                        .transition(Motion.fade)
                }
            }
            .motion(Motion.enter(Motion.Duration.quick), value: on)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension View {
    func selectionRing(_ on: Bool, radius: CGFloat = Radius.card) -> some View { modifier(SelectionRing(on: on, radius: radius)) }
}

// 읽기 창에서 J/K 로 넘길 목록(연 곳의 순서). 매거진 지면이 카드들에게 내려 준다.
private struct ReaderSequenceKey: EnvironmentKey { static let defaultValue: [NewsItem] = [] }
extension EnvironmentValues {
    var readerSequence: [NewsItem] {
        get { self[ReaderSequenceKey.self] }
        set { self[ReaderSequenceKey.self] = newValue }
    }
}

// 고른 소식에 키 동작을 한다
@MainActor
enum ItemKeys {
    static func perform(_ k: NavKey, item: NewsItem, sequence: [NewsItem], fromMagazine: Bool = false) {
        let app = AppModel.shared
        switch k {
        case .open:
            if fromMagazine { app.markOpened(item); ReaderController.open(item, sequence: sequence) } else { app.open(item, sequence: sequence) }
        case .save: app.toggleSaved(item)
        case .browser:
            ExternalLink.open(item.link)
            app.setRead(item, true)
        case .toggleRead: app.setRead(item, !app.isRead(item))
        case .next, .prev: break
        }
    }
}

// 매거진 지면에서 키보드로 고른 카드(key) — 카드들이 테두리를 그리려고 읽는다
private struct SelectedCardKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var selectedCard: String? {
        get { self[SelectedCardKey.self] }
        set { self[SelectedCardKey.self] = newValue }
    }
}
