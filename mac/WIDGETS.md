# 위젯 · 단축어 · Spotlight

> 상태: 반영됨(2026-10-13).

## 1. 이 빌드 방식(SwiftPM + build.sh)에서 되는가 — 확인 결과

**결론: (가) SwiftPM 안에서 모두 만든다.** Xcode 프로젝트는 두지 않는다.

| 기능 | 필요한 것 | 확인 |
|---|---|---|
| 위젯(WidgetKit) | `.appex` 앱 확장: 실행 파일 + `NSExtensionPointIdentifier = com.apple.widgetkit-extension` + 샌드박스 권한 | SwiftPM 실행 타깃(`@main WidgetBundle`)으로 만든 바이너리를 build.sh 가 `Contents/PlugIns/DropcapWidgets.appex` 로 조립·애드혹 서명 → `codesign --verify --strict` 통과, `pluginkit` 이 위젯 확장으로 인식(시험용 견본 등록 뒤 바로 해제) |
| 단축어(App Intents) | 빌드 때 `Metadata.appintents` 생성 | 컴파일러의 `-emit-const-values`(+ 수집할 프로토콜 목록)로 상수 정보를 뽑고 `xcrun appintentsmetadataprocessor` 로 `Contents/Resources/Metadata.appintents` 를 만든다(Xcode 가 하는 일과 같음). 견본에서 인텐트·앱 단축어가 메타데이터에 들어간 것 확인 |
| Spotlight | CoreSpotlight | 빌드 과정 변경 없음 |

### 공유 위치: App Group 대신 '읽기 전용 예외'
- 애드혹 서명에는 팀 ID 가 없어 App Group 컨테이너를 정식으로 쓸 수 없다(macOS 15 부터는 다른 앱 컨테이너 접근 시 확인 창이 뜸).
- 그래서 **앱은 자기 기록 폴더(`~/Library/Application Support/Dropcap/Widget/`)에 스냅숏을 쓰고**, 위젯 확장(샌드박스)은 그 한 폴더만 읽는 권한
  `com.apple.security.temporary-exception.files.home-relative-path.read-only` 을 갖는다. 앱 쪽은 샌드박스·컨테이너가 없어 확인 창이 뜨지 않는다.
- 개발자 인증서로 정식 배포할 때(App Store 제외) 그대로 쓸 수 있다. App Store 로 간다면 App Group 으로 바꿔야 한다(그때는 이 폴더를 옮기면 됨 — 스냅숏은 언제든 다시 만들 수 있는 사본).
- `DROPCAP_DATA_DIR` 로 띄운 시험 실행은 그 폴더 아래 `Widget/` 에 쓴다(실제 위젯은 읽지 않음).

### 하지 못한 확인
- 화면 캡처 권한이 없어 **위젯이 실제 알림 센터에 그려지는 모습**과 **단축어 앱 목록에 뜨는지**는 이 Mac 에서 눈으로 보지 못했다. 설치(/Applications) 뒤 사용자 확인이 필요하다.
- 위젯 화면은 앱의 시험 훅(`DROPCAP_TEST_WIDGET`)으로 같은 SwiftUI 화면을 그림 파일로 찍어 확인한다.

## 2. 구현 요약
- `Sources/DropcapShared/` — 스냅숏 형식(`WidgetSnapshot`, version 1, ISO8601), `dropcap://open?key=` 주소, 위젯 화면(소·중, 미리 보기 모드).
- `Sources/DropcapWidgets/` — 위젯 확장(오늘의 소식: 표지·안 읽은 수·최신 3건, 30분마다 다시 읽음).
- `Sources/Dropcap/Integrations/`
  - `WidgetExporter` — 확인·안 읽은 수 변경 때 `Store.dir/Widget/snapshot.json` + 480px JPEG 를 쓰고 `WidgetCenter` 갱신. 알림 목록이 짧으면 오늘 매거진 기사로 채움.
  - `URLRouter` — `dropcap://open?key=`·`dropcap://magazine`. host 별 `URLRouter.register("save") { ... }` 로 확장(작업자 C). `AppDelegate` 확장의 `application(_:open:)` — `open -a … dropcap://…` 로 처음 실행·실행 중 모두 동작 확인.
  - `SpotlightIndexer` — 나중에 읽기·스크랩 색인, 지우면 색인 삭제(`spotlight-index.json` 으로 차이만), 결과 누르면 읽기 창. `DROPCAP_DATA_DIR` 시험 실행은 실제 색인을 건드리지 않음.
  - `Intents` — 최신 소식 가져오기(분야·개수), 주소를 나중에 읽기로 저장, 매거진 열기 + 앱 단축어 3개.
  - `Integrations` — 시작 한 줄(App.swift), 설정 > 일반의 켜고 끄기(끄면 사본·색인 삭제), 시험 훅 `DROPCAP_TEST_WIDGET=<초>`.
- 고친 기존 파일(최소): Package.swift(타깃 2개), App.swift 1줄, SettingsView 1줄, Info.plist(`CFBundleURLTypes` dropcap — C 와 겹칠 수 있음), build.sh(appex 조립·메타데이터·서명 순서; `--deep` 제거).
- 분야는 지금 `NewsCategory` 문자열. 작업자 A 의 Section 이 들어오면 `IntentLogic.section` 만 바꾸면 된다.

## 3. 남은 확인(사용자)
- /Applications 설치 뒤: 알림 센터 위젯 갤러리에 'Dropcap — 오늘의 소식'이 보이는지, 단축어 앱에 동작 3개가 보이는지, Spotlight 에서 저장 기사가 찾아지는지.
