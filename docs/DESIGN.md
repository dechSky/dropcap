# Dropcap 디자인 시스템

코드: `mac/Sources/Dropcap/UI/DesignSystem.swift` (토큰 한 곳). 이 문서는 원칙·토큰 표·쓰는 법·하지 말 것, 그리고 1단계 점검 결과를 담는다.
윈도우·리눅스는 2단계에서 같은 이름·같은 값으로 옮긴다.

## 원칙

1. **역할이 같으면 값도 같다.** "나타남"은 어느 화면에서든 같은 시간·곡선. 카드는 어디서든 같은 모서리·그림자.
2. **움직임은 차분하게.** 빨리 와서 부드럽게 멈춘다. 끝자리를 넘어 튀지 않는다(스프링 감쇠 0.86 이상). 한 번에 크게 움직이는 것은 하나.
3. **나감은 들어옴보다 짧다.** 사라지는 것은 시선을 끌지 않는다.
4. **동작 줄이기를 따른다.** 시스템 '동작 줄이기'가 켜지면 위치·크기 움직임은 없애고 0.15초 페이드만.
5. **숫자를 화면 코드에 쓰지 않는다.** `DesignSystem.swift` 의 이름을 쓴다. 새 값이 필요하면 거기에 이름을 더한다.

## 토큰

### 움직임 `Motion`

| 이름 | 값 | 쓰는 곳 |
|---|---|---|
| `Duration.quick` | 0.15초 | 마우스 올림·누름·키보드 고름·나감 |
| `Duration.standard` | 0.25초 | 나타남/사라짐·내용 바뀜·**창 열기** |
| `Duration.slow` | 0.4초 | 지면 넘김·큰 표지·사진 뜸 |
| `enter(_:)` | 곡선 (0.2, 0.9, 0.25, 1) | 들어옴(감속) |
| `exit(_:)` | 곡선 (0.4, 0, 1, 1), 기본 quick | 나감(가속) |
| `change(_:)` | easeInOut | 자리 안 바뀜(테마·스크롤 이동) |
| `snap` | spring 0.3 / 0.86 | 손에 닿는 것: 올림·고름·펼침·토스트 |
| `settle` | spring 0.5 / 0.88 | 큰 배치: 지면 넘김·카드 깔림·지면 머리 |
| `stagger(i)` | 0.04초 × i, 최대 0.3초 | 차례로 깔림 |
| `loop(period)` | linear 반복 | 불러오는 중 회전 등 이어지는 움직임만 |
| 전환 `fade` / `rise` / `drop` / `pop` | 투명 / 투명+아래 8pt / 투명+위 8pt / 투명+0.96 | 나타남·사라짐은 이 넷만(`drop` 은 위에 붙은 막대·띠) |
| 전환 `page` | 새 지면 `rise` · 이전 지면 `exit` 페이드 | 매거진 지면 넘김 |
| `WindowMotion.present(w)` | 제자리 0.96→1 + 투명 0→1, 0.25초 enter | 모든 앱 창 열기(읽기·매거진·분야 고르기·사진 번역). 설정 창은 SwiftUI `Settings` 장면이라 시스템이 연다 |

움직임 성격을 '경쾌'로 바꾸려면 `Motion.springDamping` 하나만 0.74 로 낮춘다(snap 이 3% 쯤 튐).

### 간격 `Space` (4 배수)

`xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32 · xxxl 40` · 매거진 지면 좌우 여백 `page 36`.

### 모서리 `Radius`

`xs 4`(작은 표·배지) · `control 8`(단추·입력칸·작은 사진) · `card 14`(카드·안내 상자) · `panel 20`(큰 표지·떠 있는 판) · 칩·배지는 `Capsule()`. 모두 `style: .continuous`.

### 글자 `Font.ds…` (Pretendard ↔ 시스템 글꼴 설정을 따름)

| 이름 | 크기·굵기 | 역할 |
|---|---|---|
| `dsHero` | display 38 bold | '오늘' 지면 머리(제호) 하나 |
| `dsTitle` | display 32 bold | 지면 제목(스토리·저장·검색·스크랩북·호)·표지 기사·분야 고르기 |
| `dsHeading` | display 20 semibold | 지면 안 묶음 제목·빈 화면 제목 |
| `dsSubheading` | display 16 semibold | 카드 제목·작은 묶음 제목 |
| `dsHeadline` | 15 semibold | 카드 제목·창 안 머리 |
| `dsBody` / `dsBodyStrong` | 13 / 13 semibold | 화면 본문 |
| `dsCallout` | 12 | 요약·설명 줄 |
| `dsCaption` | 11 | 출처·시간 |
| `dsChip` | 11 semibold | 칩·배지·작은 단추 |
| `dsMicro` | 9.5 semibold | 건수·발행 중 |

읽기 창 본문 글자는 사용자가 고르는 값이라 `ReaderLook` 이 따로 정한다(토큰 밖).

### 색 `Palette` (의미 이름 · 시스템 색이라 밝은/어두운 모드를 따름)

`canvas`(매거진·읽기 바탕) · `surface`(창·설정) · `raised`(사진 없는 카드) · `ink` · `inkSecondary` · `inkTertiary` · `separator` · `accent` · `paid`(유료·맛보기, 주황) · `live`(발행 중, 빨강) · `positive` · `caution` · `section(id)`(분야색, 데이터에서).

### 높이 `Elevation` + `.elevation(_:)`

| 이름 | 그림자(검정 투명도 · 번짐 · 아래) | 쓰는 곳 |
|---|---|---|
| `flat` | 없음 | 평평한 목록 |
| `low` | 0.08 · 4 · 1 | 칩·작은 단추 |
| `card` | 0.12 · 10 · 4 | 카드 평소 |
| `raised` | 0.2 · 18 · 10 | 카드 마우스 올림 |
| `floating` | 0.28 · 26 · 14 | 떠 있는 판·표지 |

유리: 창 머리·떠 있는 막대는 `.regularMaterial` 하나(`chromeGlass(in:)`). macOS 26 `glassEffect` 는 알림 물방울에만.

## 쓰는 법

```swift
withMotion(Motion.snap) { hover = h }                 // withAnimation 대신(동작 줄이기 따름)
.motion(Motion.enter(), value: phase)                 // .animation(_, value:) 대신
.transition(Motion.rise)
.onAppear { withMotion(Motion.settle.delay(Motion.stagger(i))) { on = true } }
.padding(Space.l).background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
.elevation(hover ? Elevation.raised : Elevation.card)
Text(title).font(.dsHeadline)
WindowMotion.present(w)                               // w.makeKeyAndOrderFront 대신(새 창일 때만)
```

## 하지 말 것

- `.easeOut(duration: 0.18)` 처럼 화면 코드에 시간·곡선 숫자 쓰기. `.spring(response:…)` 새로 만들기.
- 한 덩어리(지면 머리 등) 안에서 요소마다 다른 곡선·지연 쓰기 — 같은 곡선 + `stagger`.
- 나타남에 회전·큰 이동(20pt 넘게)·0.9 미만 크기 쓰기.
- 0.4초보다 긴 움직임(이어지는 `loop` 와 물방울 고유 연출 제외).
- 창마다 다른 열기 방식. 이미 열린 창을 앞으로 부를 때 움직이기.
- 동작 줄이기를 확인하지 않는 `withAnimation` / `.animation`.
- 같은 역할 카드에 다른 모서리·그림자.

## 예외(그대로 둠)

- **알림 물방울**(`Toast/`): 떨어짐·잔 눌림·물 차오름은 제품의 고유 연출이라 자체 값을 쓴다. 다만 마우스 올림은 `snap`, 사라짐은 `exit` 로 맞춘다.
- **이어지는 움직임**: 불러오는 중 회전(0.9·1.4초)은 `loop`, 매거진 사진 흐름(22초 왕복)·저녁 정리 진행 막대(건수에 맞춘 시간)는 고유 주기.
- **알림 패널**(`ToastCenter`): 화면을 옮겨 갈 때의 페이드(0.14·0.2초)와 들어옴 스프링은 물방울 연출과 함께 둔다.
- **글자 크기 그대로 둔 곳**: 기호 크기(26~34 light), 상표 글자("Dropcap" 16 heavy, 분야 사진 카드 19 heavy), 조건으로 크기가 바뀌는 곳(`compact ? 11 : 13` 등), 14~16 보통 굵기 본문(읽기 창 요약·원제), 읽기 창 본문(`ReaderLook`).
- **시험·견본 화면**(`SectionCardLab`·`*TestHooks`)은 숫자 그대로.

---

## 1단계 점검 결과 (2026-10-16, main bc75cc9)

`grep` 으로 맥 화면 코드(UI·Reader·Toast·App, E2E 제외) 전부를 셌다.

### 움직임 — 같은 역할, 다른 값

| 역할 | 지금 쓰는 값(파일:줄) | 제안 |
|---|---|---|
| 마우스 올림 | easeOut 0.15 (ImageTools:27, MenuStyles:109, ReaderView:798) · spring .3/.8 (SectionPhotos:93) · spring .35/.75 (MagazineView:790) · spring .4/.8 (MagazineView:586) · spring .3/.75 (ToastView:114) | `snap` |
| 고름·펼침 | spring .3/.8 (SectionPhotos:94) · spring .35/.85 (MagazineView:1350) · spring .4/.85 (SectionViews:209) · easeOut 0.18 (SectionViews:44, ReaderView:524) · easeOut 0.12 (KeyNav:70) | `snap` / `quick` |
| 사진 뜸 | easeOut 0.25 (MenuView:376) · 0.3 (ReaderView:105,893, ToastView:351) · 0.35 (ReaderView:932, SectionPhotos:22) · 0.5 (RemoteImage:124) | `enter(slow)` + `fade` |
| 내용 바뀜(읽기 로딩→본문) | easeOut 0.2 (ReaderView:48) · 0.3 (ReaderView:74) | `enter()` |
| 작은 알림 들어옴/나감 | spring .3 / easeOut .25 (ReaderView:317-318) · spring .35/.85 / easeOut .25 (ReaderView:413-416) | `snap` / `exit()` |
| 스크롤로 옮김 | easeOut 0.15 (MenuView:122) · 0.2 (MagazineView:360) · easeInOut 0.25 (ReaderView:185) | `change()` |
| 지면 머리 깔림 | easeOut .5 · spring .6/.85+.06 · easeOut .5+.12 · spring .9/.9+.1 · 표지 spring .7/.85+.15 (MagazineView:332,448-460) — 다섯 개가 제각각, 끝까지 1초 넘음 | `settle` + `stagger` (0.66초) |
| 카드 차례로 깔림 | spring .55/.86 + 0.05씩 최대 0.4 (MagazineView:805) · spring .5/.85 + 0.05 최대 0.5 (:1205) · spring .5/.86 + 0.05 최대 0.4 (:1496) · spring .4/.85 + 0.14+0.045 (ToastView:469) | `settle` + `stagger` |
| 지면 넘김 | spring .62/.9 + 회전 28°/70° 넘김(MagazineView:64,120,151) | `settle`, 들어옴 `rise` · 나감 `fade` |
| 호 다시 엮임 | easeOut 0.4 (MagazineView:387,397) · spring .5/.85 (:366) | `settle` |
| 새 기사 띠 | spring .45/.8 + move(top) (MagazineView:377-380) | `snap` + `rise` |
| 오늘 다 읽음 | spring .5/.85 + scale .98 (TodayViews:27,42) | `settle` + `pop` |
| 알림 패널 들어옴 | spring .5/.82 (ToastCenter:80,89) | 예외(물방울 연출) |
| 전환 종류 | opacity · opacity+offset(8) · opacity+scale(.8/.98) · move(top)+opacity · move(bottom)+opacity · pageTurn | `fade` · `rise` · `pop` 셋 |
| 동작 줄이기 | 따르는 곳 10곳 남짓, 나머지(카드 올림·깔림·지면 머리·사진 등)는 안 따름 | 모두 `withMotion` / `.motion` |

### 창 열기

| 창 | 지금 | 제안 |
|---|---|---|
| 읽기 창 (ReaderView:705-720) | 카드 자리에서 투명 0.2 → 창 크기로 0.38초 커짐 | `WindowMotion.present` |
| 매거진 (MagazineView:1235-1254) | 움직임 없음 | 같음 |
| 분야 고르기 (SectionViews:265-276) | 움직임 없음 | 같음 |
| 설정·사진 번역 (App/ImageTools:276) | 움직임 없음 | 같음 |
| 알림 패널 (ToastCenter) | 페이드 0.14 / 0.2, 포커스 뺏지 않음 | 예외(그대로) |

→ 읽기 창만 혼자 크게 움직이고 나머지는 툭 뜬다. 이것이 "창 열기가 정리 안 돼 보임"의 주 원인.

### 글자

`.app()`/`.display()` 로 **크기 30가지 남짓**(9·9.5·10·10.5·11·11.5·12·12.5·13·13.5·14·14.5·15·15.5·16·17·18·19·20·22·26·28·30·34·38·44) × 굵기 6가지. 0.5pt 차이(11 vs 11.5, 12 vs 12.5, 13 vs 13.5)가 같은 역할에 섞여 있다. `.font(.caption)` 29곳은 Pretendard 설정을 따르지 않는다. → 10개 역할로.

### 간격

padding 값 29가지(1~80), spacing 18가지. 4 배수 아님: 1·3·5·7·9·11·13·14·18·22·26·30·34 / 1·3·5·7·9·11·14·18·22·26. 많이 쓰는 14(29곳)·18(13곳)은 12·16 으로, 28(11곳)은 24·32 로 맞춘다.

### 모서리

2·3·4·5·6·7·8·9·10·12·14·16·22 — 13가지. 카드만 12·14·16 셋이 섞임(선택 고리 16, 카드 14, 안내 상자 12). → 4가지 + Capsule.

### 그림자

검정 투명도 0.06~0.5, 번짐 6~26 로 18가지 조합. 카드 올림이 0.16→0.28(MagazineView:584)과 0.06→0.18(:775)로 다르다. → 5단계.

### 색

`.secondary` 117곳·`.tertiary` 23곳은 시스템 색이라 문제 없음. 유료 주황·발행 중 빨강이 이름 없이 흩어져 있고(`Color.orange` 16곳), 바탕이 `textBackgroundColor`/`windowBackgroundColor`/`Color(white:)` 로 섞임. → 의미 이름.

### 유리

`.regularMaterial` 9 · `.thinMaterial` 2 · `glassEffect` 2(물방울). → 창 머리·막대는 regular 하나.

## 윈도우·리눅스

같은 이름·같은 값을 쓴다.

| 맥 | 윈도우(웹 화면 `web/base.css`, 창 `Dropcap.App/Motion.cs`) | 리눅스(`dropcap-gtk/src/motion.rs`, CSS 문자열) |
|---|---|---|
| `Motion.Duration.quick/standard/slow` | `--dur-quick/standard/slow` · `Motion.Quick/Standard/Slow` | `motion::QUICK/STANDARD/SLOW`(ms) |
| `enter()` · `exit()` · `change()` | `--ease-enter/exit/change` | `motion::ENTER`(EaseOutQuint) · `EXIT`(EaseInCubic) · `CHANGE`(EaseInOutCubic) — libadwaita 에 임의 곡선이 없어 가장 가까운 것 |
| `snap` · `settle` 스프링 | `--dur-snap --ease-snap` · `--dur-settle --ease-settle`(`linear()` 로 옮긴 같은 스프링) | `SETTLE`(500ms) + `ENTER` |
| `stagger(i)` | `--stagger`(JS `--d` 0.04초씩 최대 0.3) | `motion::stagger(i)` |
| `fade/rise/drop/pop` · `page` | `ds-fade/ds-rise/ds-drop/ds-pop` · 지면 넘김 `ds-rise` + `ds-out` | 지면 넘김 `Crossfade`(SETTLE) |
| `WindowMotion.present` | `WebWindow.Present()` — 창 틀은 0.96→1, 내용(WebView)이 0→1(WinUI 창은 투명도를 못 바꿈) | `motion::present` — 투명도만 0→1(GTK4 는 창 크기 움직임 불가) |
| `Space` · `Radius` · `Font.ds…` · `Elevation` | `--sp-*` · `--r-*` · `--fs-*` · `--el-*` | 매거진 카드·표지·테마 CSS 의 모서리·그림자·칩 글자를 같은 값으로 |
| 동작 줄이기 | `.reduce-motion` + `@media (prefers-reduced-motion)` | `motion::enabled()`(gtk-enable-animations) |

리눅스 화면의 글자 크기·간격(코드 안 `text(…, 12.5, …)` 등)은 아직 숫자 그대로 — 다음 묶음.

## 시험

- `DROPCAP_TEST_WINDOW_MOTION=<폴더>`(디버그 빌드만): 화면 밖 창으로 `WindowMotion.present` 를 실제로 돌려 1/60초마다 배율·투명도를 재고 `window-open-<n>.png`·`window-open.txt` 를 남긴다. 앱을 앞으로 띄우지 않는다.
- 조용한 시험(`E2EQuietUI`)이 숨긴 창은 `WindowMotion` 이 다시 보이게 하지 않는다(`ignoresMouseEvents` 로 알아봄).

## 미리보기

저장소 밖 `newsletter-wt/design-shots/` — 토큰 견본, 움직임 전·후 곡선, 창 열기 선택지 프레임, 지면 머리 차례, '경쾌' 변형. 곡선·프레임은 값으로 계산해 그린 모의 그림이다(앱 화면 녹화 아님). 앱 창 전·후 스냅샷은 2단계에서 화면을 바꾼 뒤 찍는다.

## 남은 것 (2026-10-16 마무리 시점, wt/design 6043e4b 다음)

다음에 이어 할 순서:
1. **MagUI 병합 뒤 맞추기** — `wt/mag-settings` 가 `SettingsView` 구독 탭(sources)을 통째로 다시 쓰고 `MagazineView` 옆 목록·`ReaderView` 단축키를 고친다. 그쪽이 main 에 들어오면 `git merge main` 후 새 코드의 숫자(글자·간격·모서리·움직임)를 토큰으로 바꾼다. 같은 줄을 둘이 고친 곳은 MagUI 동작 + 토큰. 특히 `MagazineView` 옆 목록 바닥 '설정' 단추(safeAreaInset, MagUI 62b9599)의 간격 18·8 → `Space.l`·`Space.s`. 구독 탭은 MagUI WIP 라 그쪽이 main 에 들어온 뒤.
2. **스크랩북 클릭 순회** — 조용한 클릭 순회의 스크랩북 '직접 클릭이 닿지 않음' 실패는 main 에도 있다(대상만 다름, 기존 불안정). 다만 스크랩북 카드 귀퉁이를 `AXScrollArea` 가 덮는 1건은 바뀐 판에서만 나왔다 — 카드 모서리 12→14 영향인지 확인.
3. **리눅스 글자·간격** — 화면 코드 안의 `text(…, 12.5, …)`·`set_margin_*(n)`·`Box::new(_, n)` 숫자를 `motion.rs` 옆 `ds.rs`(새로) 토큰으로. 매거진 카드·표지·테마 CSS 는 이미 맞춤.
4. **윈도우 창 열기 실물 확인** — `WebWindow.Present()` 는 맥에서 컴파일만 확인. 윈도우 기기에서 창 틀이 0.96→1 로 커지고 내용이 흐려졌다 또렷해지는지, `MoveAndResize` 가 깜빡이지 않는지 본다. 깜빡이면 ② '페이드만'(내용 투명도만)으로 줄인다.
5. 맥 `Settings` 장면(설정 창)은 시스템이 열어 `WindowMotion` 을 안 쓴다 — 필요하면 `SettingsLink` 대신 직접 창을 만드는 방법 검토(동작은 바꾸지 않게).

주의:
- `WindowMotion.present` 는 조용한 시험(`E2EQuietUI`)이 숨긴 창을 `ignoresMouseEvents` 로 알아보고 건드리지 않는다 — 이 조건을 바꾸면 시험 창이 사용자 화면에 보인다.
- 윈도우 CSS 에서 높이의 절반 모서리(알약 모양)는 `99px` 로 둔다 — 토큰 `--r-control` 로 바꾸면 스위치가 네모나진다(한 번 겪음).
- 전·후 스냅샷: `newsletter-wt/design-shots/` (저장소 밖).
