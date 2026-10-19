# Dropcap 디자인 시스템

코드: `mac/Sources/Dropcap/UI/DesignSystem.swift` (토큰 한 곳). 이 문서는 원칙·토큰 표·쓰는 법·하지 말 것을 담는다.
윈도우·리눅스는 같은 이름·같은 값을 쓴다(아래 '윈도우·리눅스').

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
