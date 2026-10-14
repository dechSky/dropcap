import CoreText
import SwiftUI

// 글꼴: 기본은 함께 담긴 Pretendard(한글 가독성), 설정에서 시스템 글꼴로 되돌릴 수 있다.
enum Typography {
    static let family = "Pretendard Variable"
    static var usePretendard: Bool { UserDefaults.standard.object(forKey: "usePretendard") as? Bool ?? true }

    // 앱을 켤 때 한 번: 이 앱 안에서만 쓰도록 글꼴을 등록
    static func register() {
        let url = Resources.url("Fonts/PretendardVariable.ttf")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var err: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
            NSLog("[글꼴] 등록 실패: %@", err?.takeRetainedValue().localizedDescription ?? "?")
        }
    }
}

// 화면 설정(글꼴 등)이 바뀌면 열린 창들을 바로 다시 그린다(창 뿌리에 .liveAppearance())
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    @Published private(set) var epoch = 0
    func changed() { epoch += 1 }
}

struct LiveAppearance: ViewModifier {
    @ObservedObject private var appearance = Appearance.shared
    func body(content: Content) -> some View { content.id(appearance.epoch) }
}

extension View {
    func liveAppearance() -> some View { modifier(LiveAppearance()) }
}

extension Font {
    // 본문·화면 글자
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Typography.usePretendard ? .custom(Typography.family, size: size).weight(weight) : .system(size: size, weight: weight)
    }
    // 매거진 제목: 굵고 촘촘하게
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        Typography.usePretendard ? .custom(Typography.family, size: size).weight(weight) : .system(size: size, weight: weight, design: .serif)
    }
}
