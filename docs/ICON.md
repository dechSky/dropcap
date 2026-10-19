# Dropcap 아이콘

살짝 기운 종이 표지 위 붉은 첫 글자(매거진 표지).

## 도형과 쓰임

### 도형 원본은 하나: `shared/icon.json`

세 판이 같은 도형 정의를 읽습니다. 좌표는 y 아래로, 패스는 절대 좌표 `M L H V C Z` 만 씁니다(세 판 해석기가 같게 읽도록 — 호·상대 좌표 없음).

| 항목 | 내용 |
|---|---|
| `app` | 1024 격자 앱 아이콘: 824px 둥근 사각형 타일(붉은 주황 그라데이션 + 그림자), 5° 기운 종이 표지·그림자, 남색 제호 띠, 붉은 세리프 D, 글줄 |
| `small` | **32px 이하 단순화 판**: 기울기·표지 그림자·제호 띠를 없애고 표지를 크게, D 를 0.30→0.47 배로 키우고 가로획을 굵게(46→90), 글줄은 굵은 3개 |
| `smallMax` | 32 — 이 크기 이하에서 `small` 을 씀 |
| `symbol` | 16 격자 단색 상징. `read`: 표지 윤곽(굵기 1) 안 D + 글줄 3 + 아랫줄. `unread`: 채운 표지에서 D·글줄이 빠짐(한 패스 evenodd). 16·32px 에서 화소 경계에 맞춤 |

D 는 글꼴이 아니라 직접 그린 패스입니다(라이선스 걱정 없음). 층(layer)마다 `fill`/`opacity` 또는 `gradient`, `evenodd`, `rotate`([도, 중심 x, 중심 y], SVG `rotate()` 와 같음)를 가집니다.

### 판별 쓰임

| 판 | 그리는 곳 | 쓰는 곳 |
|---|---|---|
| 맥 | `mac/Sources/Dropcap/Core/IconArt.swift`(앱과 빌드 스크립트 공용) | `scripts/build.sh` 가 `IconArt.swift` + `scripts/make-icon.swift` 를 이어 붙여 iconset(16~512@2x, 16·16@2x·32 칸은 단순화 판) → `AppIcon.icns`. 위젯 확장(`DropcapWidgets.appex`)에도 같은 icns 와 `CFBundleIconFile`. 상단바는 SF `newspaper` 대신 템플릿 상징(`App.swift`, 못 읽으면 SF 기호로 돌아감). `icon.json` 은 앱 Resources 에 복사 |
| 윈도우 | `windows/Dropcap.Ui/Toast/AppIcon.cs`(SkiaSharp, `icon.json` 을 어셈블리에 포함) | `.ico`(16·24·32 는 단순화 판, 48~256 은 본판) — 빌드 때 `tools/IconGen`, 창 아이콘은 `Platform.EnsureIcon`(예전 물방울 파일이 남아 있으면 새 그림으로 덮음). 트레이 `AppIcon.Tray`(작업 표시줄 색에 맞춘 흰색·검은색). 시스템 알림은 실행 파일 아이콘을 씀 |
| 리눅스 | `linux/resources/icons/*.svg` — **`icon.json` 에서 만든 파일**(손으로 고치지 않음) | `io.github.dechsky.Dropcap.svg`(scalable), `small/io.github.dechsky.Dropcap.svg`(AppImage 의 16·24·32 칸), 트레이 `dropcap-newspaper(-filled)-symbolic.svg`(이름은 그대로 두어 `tray.rs`·설치본을 안 건드림) |

### 도형을 고칠 때

1. `shared/icon.json` 을 고칩니다.
2. 리눅스 SVG 다시 만들기: `cd linux && DROPCAP_ICON_UPDATE=1 cargo test -p dropcap-core --test icon_svg_tests` (평소 `cargo test` 는 SVG 가 json 과 다르면 실패 — 어긋남 방지).
3. 맥·윈도우는 빌드 때 json 을 읽으므로 따로 할 일 없음. 시험: 윈도우 `ToastTests.IconArtFromSharedJson`(단순화 판·트레이 두 상태), `DROPCAP_TOAST_FRAMES=<폴더>` 로 PNG 를 뽑아 볼 수 있음.
