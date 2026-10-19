# Dropcap

> 드롭캡(dropcap): 잡지 첫 글자를 크게 키우는 조판 방식. 그리고 상단바에서 똑 떨어지는(drop) 소식.

관심 분야(정치·경제·사회·국제·IT·AI·과학·생활·문화·스포츠·기후 등)의 국내외 언론 소식을 모아 **매거진으로 엮어 보여 주고**, 여러 곳이 함께 다룬 큰 소식만 상단바에서 물방울이 맺혀 똑 떨어지듯 알려 주는 상단바 앱입니다. 분야마다 '즉시 · 저녁 묶음 · 매거진에만' 중 알림 방식을 고를 수 있습니다. 기사를 누르면 광고 없이 본문만 추린 읽기 창이 열리고, 외국어 기사는 한국어로 번역해 보여 줍니다.

> Dropcap is a menu-bar news magazine. It collects Korean and international outlets by section (politics, economy, tech, AI, science and more), binds them into daily and weekly issues, and only interrupts you — with a drop that falls from the menu bar — when a story is covered by several outlets. Each section can notify instantly, as an evening bundle, or stay in the magazine only. Articles open in a clean reader with Korean translation. Native apps for macOS, Windows and Linux.

| 판 | 상태 | 위치 |
|---|---|---|
| macOS (Swift · SwiftUI · AppKit) | 기준 판 | [`mac/`](mac/) |
| Windows (C# · WinUI 3 + WebView2) | 맥과 같은 기능을 옮김(맥에서 시험·컴파일 점검), 윈도우 실기 확인 남음 | [`windows/README.md`](windows/README.md) |
| Linux (Rust · GTK4 · libadwaita) | 맥과 같은 기능을 옮김(맥에서 GTK 로 실행 확인), 리눅스 배포판 실기 확인 남음 | [`linux/README.md`](linux/README.md) |

기능 목록은 [`docs/FEATURES.md`](docs/FEATURES.md), 시험은 [`docs/TESTING.md`](docs/TESTING.md), 디자인 토큰은 [`docs/DESIGN.md`](docs/DESIGN.md).

## 맥 판

- macOS 14 이상. 기기 내 번역·3줄 요약·저녁 정리(Apple Intelligence)와 유리(Liquid Glass) 물방울은 macOS 26 이상

### 매거진 (⌥⌘M)
- **오늘 호 · 이번 주 · 지난 호**(하루·한 주가 지나면 자동 발행). 표지 기사 + 분야별 지면(분야색 유리 띠 머리) + 구독 채널 지면(영상·논문·릴리스·커뮤니티·팟캐스트). 이번 주는 달력 한 주(지난 주간과 이어짐), 주간 표지는 그 주 가장 많이 다룬 이야기.
- **분야 지면**: 왼쪽 목록의 분야를 누르면 그 분야 기사만으로 엮은 지면(AI 는 모델·연구·정책·투자·보안·기타 하위 칩).
- 머리 숫자는 지면에 실린 것 기준("소식 N건 중 M건 실음"). 오늘 호 대표 기사를 다 읽으면 완독 표시.
- **스토리**: 같은 소식을 다룬 여러 곳을 한 줄기로 묶고(영어·한국어 기사도 뜻으로 이어 줌), 해외·국내 보도를 나란히. 팔로우하면 새 보도가 붙을 때 알림.
- **저녁 정리**: '묶음' 분야는 묶음을 보낼 때 그 분야 기사를 기기 안에서 세 줄로 정리해 지면 위에 근거 기사와 함께 둡니다(Apple Intelligence).
- 스크랩북(문단·기사 스크랩, 폴더·메모, Markdown 복사·저장), 저장(번역까지 보관해 오프라인으로 읽기), 전체 기록 검색(지켜볼 낱말·최근 검색 칩).
- 정렬: 추천순 / 최신순 / 많이 보도된 순 / 출처별. 편집 점수는 공식 발표 · 여러 곳 보도 · ★ 낱말 · 자주 읽는 분야·출처 · 최신성.

### 알림
- **분야별 정책**: 즉시(여러 곳이 다룬 소식만, 분야마다 하루 상한을 넘으면 고였다가 묶음으로) · 묶음(기본 18시에 "경제 N건" 한 방울) · 매거진에만. 모든 분야를 합친 하루 상한(기본 10)이 있고, 아주 큰 소식(국내 8곳 이상)은 상한을 넘어 알립니다.
- 알림 모양: **물방울**(상단바 아래에서 맺혀 떨어지고, 유리 카드에 물이 차올랐다가 천천히 빠지며 남은 시간을 보여 줌) 또는 시스템 알림 센터. 위치는 위쪽 가운데(노치가 있으면 노치에서)·오른쪽 위.
- 같은 소식은 한 번만("외 N곳"), ★ 꼭 알림 / 알리지 않음 낱말, **지켜볼 낱말**(회사·인물·법안 — 스토리마다 한 번 + 하루 한 번 정리 물방울), 방해 금지 시간, 아침 브리핑.
- **회의 중 조용히**: 전체 화면 앱·화면 공유/기록·캘린더 일정 중에는 물방울 없이 '안 읽음'에 쌓습니다(설정에서 하나씩 켜고 끔).

### 읽기
- Mozilla Readability 로 본문만 추립니다. HTML 만 받아 먼저 시도하고, 스크립트로 본문을 그리는 사이트는 페이지에 실린 본문 자료를 읽거나 열 때만 실제로 띄웁니다. 못 열면 까닭(차단·없어진 페이지·글 없는 영상 기사·연결 문제)에 맞는 안내와 피드 요약을 보입니다.
- 원문을 먼저 보이고 번역이 위에서부터 바뀝니다. 번역/원문 전환, 모양(글꼴·크기 ⌘- / ⌘=·줄 간격·폭·자동/종이/어둡게), 찾기(⌘F·⌘G), 소리 내어 읽기, 3줄 요약, 기사 속 사진의 글자 번역·복사·저장, 주소 복사(⌘⇧C).
- **유료 기사 표시**: 유료·자주 막히는 출처에 자물쇠, 막힌 기사에는 같은 스토리의 무료 보도를 먼저 권합니다.

### 상단바 창
- 전체 / 안 읽음 / 저장 탭, 첫 소식을 크게 보이는 목록, 분야 칩, 정렬, 검색, 모두 읽음.
- 키보드: ↑↓ 또는 J·K 이동 · ⏎ 열기 · S 나중에 읽기 · O 브라우저 · M 읽음/안 읽음. 매거진은 ⌘1 오늘 · ⌘2 이번 주 · ⌘3 스토리 · ⌘4 스크랩북 · ⌘F 검색 · ⌘[ ⌘] 지면 넘기기 · ⌘R 새로 확인 · ⌘, 설정(옆 목록 맨 아래 '설정' 줄도). 어디서나 ⌥⌘N 가장 최근 안 읽은 소식 · ⌥⌘M 매거진.

### 구독·연동
- 기본 출처 147곳(국내 82 · 해외 65, `shared/sources.json`). 처음에 고른 분야의 출처가 켜집니다. 설정 › 구독에서 아무 주소나 추가(웹사이트 피드 자동 발견·Substack·Medium·YouTube·GitHub 릴리스·Reddit·arXiv·팟캐스트), OPML 내보내기·가져오기.
- 위젯('오늘의 소식': 오늘의 표지·최신 소식·안 읽은 수), 단축어('최신 소식 가져오기'·'주소를 나중에 읽기로 저장'·'매거진 열기'), Spotlight(저장·스크랩), 서비스 메뉴 'Dropcap 에 저장', `dropcap://save?url=…`, 북마클릿, 노트 폴더로 스크랩 내보내기.
- **내 기록 내보내기·가져오기**(설정 › 일반): 저장·스크랩·폴더·구독·분야·알림 설정·낱말·숨긴 출처를 JSON 하나로. 가져오기는 없는 것만 더하고, 가져오기 전 기록을 남겨 되돌릴 수 있습니다(집·회사 Mac 옮기기).

## 번역과 개인정보

- **번역**: macOS 26 이상에서 영어→한국어 언어 자료가 있으면 Apple 기기 내 번역(Translation 프레임워크). 없으면 Google 번역 공개 엔드포인트를 씁니다 — 이때 기사 문장이 Google 로 전송되며, 공식 API 가 아니라 언제든 막힐 수 있습니다. 설정 › 일반 › 번역에서 기기 내 자료를 받을 수 있습니다.
- **요약·저녁 정리**: Apple Intelligence(기기 안 모델)만 씁니다. 외부 AI 서비스로 보내지 않습니다.
- **저장 위치**: `~/Library/Application Support/Dropcap/` — 설정(native-state.json), 매거진·스토리·스크랩 기록(magazine.sqlite, 스크랩 사본 scraps.json), 기사·사진 캐시. 계정·서버·분석·추적 없음.
- **안전**: 피드에서 온 주소는 믿지 않습니다. 공개 인터넷 주소만 받고(이름을 실제 IP 로 풀어 확인, 접속한 IP 도 다시 확인), 받는 크기에 상한(피드 10MB · 기사 페이지 2MB · 사진 8MB)을 두며, 알림 때 미리 받기는 사이트 스크립트를 돌리지 않습니다.

## 빌드 (맥)

Xcode 26 이상(Swift 6 도구)이 필요합니다.

```bash
cd mac
swift build            # 개발용 빌드
swift test             # 시험
./scripts/build.sh     # build/Dropcap.app 과 build/Dropcap-<버전>.dmg (애플 실리콘·인텔 공용, 위젯 확장 포함)
```

개발자 인증서가 없으면 이 Mac 전용 임시 서명으로 만들어집니다. 다른 Mac 에서 열 때는 시스템 설정 › 개인정보 보호 및 보안 › "그래도 열기"가 필요합니다. 인증서가 있으면 `MAC_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build.sh`.

시험용 환경 변수(`DROPCAP_DATA_DIR` 를 함께 주면 실제 기록을 건드리지 않음):

```bash
DROPCAP_DATA_DIR=$(mktemp -d) .build/debug/Dropcap                     # 시험용 폴더로 실행
DROPCAP_TEST_TOAST=1 .build/debug/Dropcap                               # 실행하자마자 알림 미리 보기
DROPCAP_TEST_URL=<기사 주소> .build/debug/Dropcap                        # 읽기 창 바로 열기
DROPCAP_TEST_MAGAZINE=1 .build/debug/Dropcap                             # 매거진 바로 열기
DROPCAP_TEST_READSWEEP=<결과 폴더> .build/debug/Dropcap                  # 기본 출처 본문 추출 전수 점검
DROPCAP_LIVE_TESTS=1 swift test                                         # 실제 서버로 피드·주소 해석 시험
```

Windows·Linux 빌드는 각 [`windows/README.md`](windows/README.md), [`linux/README.md`](linux/README.md).

## 구조

```
shared/                    출처(sources.json)·분야(categories.json) — 세 판 공용
mac/
  Sources/Dropcap/
    Core/          피드 받기·해석, 안전 검사, 번역, 요약, 분야·알림 정책, 구독 채널, 매거진 편집(Editor)·DB, 스토리 묶기,
                   스크랩, 상태 저장·내보내기, 유료 표시, 회의 중 조용히, 지켜볼 낱말, 단축키
    Toast/         물방울(DripView) · 물 차오름(WaterFill) · 알림 카드와 패널
    Reader/        본문 추출(Readability·실린 본문 자료), 미리 받기·캐시, 읽기 창, 찾기·모양, 소리 내어 읽기
    UI/            매거진, 상단바 창, 설정, 분야 유리 카드, 사진 로더, 키보드 탐색
    Integrations/  단축어(App Intents), Spotlight, 위젯 자료, 주소 스킴
  Sources/DropcapWidgets/  위젯 확장
  Resources/   Info.plist, Readability.js, Fonts/(Pretendard)
  Tests/       시험
  scripts/     빌드·아이콘
windows/  linux/           다른 판(각 README)
docs/                      기능 목록(FEATURES)·시험(TESTING)·디자인(DESIGN)·아이콘(ICON)
```

## 라이선스

[MIT](LICENSE). 포함된 외부 코드는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 를 보세요.

기사 내용의 저작권은 각 언론사·기업에 있습니다. 이 앱은 원문 링크로 이어 주며, 본문을 다시 배포하지 않습니다.
