# 일반 뉴스 전환 — 분야·출처 자료, 피드 날짜 내성, 출처 건강, OPML (작업자 B)

> 상태: 반영됨(2026-10-13).

브랜치 `wt/feeds-data`. 근거 자료: `docs/research/COMPETITIVE.md` (다)-2, `docs/research/feeds.json`.

## 1. 자료

### `shared/categories.json` (새 파일)
계약 그대로 12개다(`top` 은 `flow: true`, `climate` 는 `more: true`). id·이름·기호·색은 계약 문서와 같다.

### `shared/sources.json` (version 2)
- 출처는 **120곳**이다. 기존 AI 14곳에 새로 106곳을 더했다(Nature 는 아래 사유로 뺌).
- `defaultOn: true` 는 39곳이다. 국내(`region: kr`) 70곳, 해외 50곳이다.
- 모든 항목에 `section`·`lang`·`region` 이 있다.
  - 기존 AI 출처는 id 를 바꾸지 않고 `section: "ai"` 로 두었다.
  - 새 국내 언론은 `tier: "kr"`, 해외 언론은 `tier: "press"` 다. 코리아헤럴드는 `lang: "en"`, `region: "kr"` 이다.
- `notifyDefault: false` 는 Hacker News 1면(`kind: post`) 하나에만 붙였다. 하루 글이 많은 통신사 피드에도 붙이지 않았다. 알림은 분야 단위로 정한다(작업자 A).
- 모든 주소를 2026-10-13 에 다시 받아 확인했다. 앱 파서로 실제 피드를 받는 시험도 통과했다(아래 4).

| 분야 | 수 | 기본으로 켜짐(★) | 추천(꺼짐) |
|---|---|---|---|
| 주요 뉴스 (`top`) | 8 | SBS 주요뉴스 · BBC News | 연합뉴스 최신 · MBC 주요뉴스 · 조선일보 · The New York Times · NPR News · The Korea Herald |
| 정치 (`politics`) | 9 | 연합뉴스 정치 · 동아일보 정치 · NYT Politics | 경향신문 정치 · SBS 정치 · 연합뉴스 북한 · 한국경제 정치 · 노컷뉴스 정치 · Politico |
| 경제 (`economy`) | 18 | 연합뉴스 마켓+ · 한국경제 증권 · CNBC · BBC Business | 연합뉴스 경제 · 연합뉴스 산업 · 매일경제 증권 · 매일경제 경제 · 서울경제 경제 · 서울경제 증권 · 조선일보 경제 · 한국경제 경제 · 한국경제 부동산 · 경향신문 경제 · WSJ Markets · MarketWatch · NYT Business · Guardian Business |
| 사회 (`society`) | 7 | 연합뉴스 사회 · 경향신문 사회 | 동아일보 사회 · SBS 사회 · 한겨레 사회 · 노컷뉴스 사회 · 연합뉴스 전국 |
| 국제 (`world`) | 12 | 연합뉴스 국제 · BBC World · Guardian World | 경향신문 국제 · 동아일보 국제 · SBS 국제 · 한겨레 국제 · 한국경제 국제 · NYT World · Al Jazeera · DW News · NPR World |
| IT (`tech`) | 14 | 블로터 · GeekNews · The Verge · Ars Technica | ZDNet Korea · 전자신문 전체 · 테크M · 디일렉 · 한국경제 IT · 노컷뉴스 IT · TechCrunch · WIRED · Hacker News 1면 · BBC Technology |
| AI (`ai`) | 15 | (기존 그대로) OpenAI · Anthropic · Google DeepMind · Google AI · NVIDIA · MIT Technology Review · Ars Technica · The Verge · AI타임스 | Hugging Face · AWS ML · TechCrunch · WIRED · 전자신문 · 전자신문 AI(새) |
| 과학 (`science`) | 9 | 동아일보 의학·과학 · Quanta Magazine · BBC Science | 전자신문 과학 · 경향신문 과학 · 한겨레 과학 · ScienceDaily · New Scientist · NASA |
| 생활·건강 (`life`) | 8 | 연합뉴스 건강 · BBC Health | 동아일보 건강 · 코메디닷컴 · 전자신문 바이오 · 경향신문 라이프 · STAT · NYT Health |
| 문화·연예 (`culture`) | 10 | 연합뉴스 문화 · 동아일보 문화 · Guardian Culture | 연합뉴스 연예 · SBS 연예 · SBS 생활·문화 · 한겨레 문화 · 조선일보 문화·라이프 · 노컷뉴스 문화 · NYT Arts |
| 스포츠 (`sports`) | 7 | 연합뉴스 스포츠 · BBC Sport | SBS 스포츠 · 동아일보 스포츠 · 한겨레 스포츠 · 노컷뉴스 스포츠 · ESPN |
| 기후·환경 (`climate`) | 3 | Guardian Environment · Carbon Brief | Inside Climate News |

- 사회는 해외 기본 출처가 없다(국내 중심 분야). 기후는 국내 전용 피드를 찾지 못했다.
- 넣지 않은 것은 다음과 같다.
  - 죽은 주소(404): 정책브리핑, 연합 IT, 동아사이언스, 사이언스타임즈, 한겨레 기후, 중앙 영문, NHK 영어
  - HTML 을 돌려주는 주소: 뉴스1, 디지털데일리
  - 갱신이 멈춘 곳: JTBC, NHK 일본어, 경향 IT
  - XML 이 깨진 곳: 헬로디디
  - 하루 수백~천 건이 나오는 곳: 파이낸셜뉴스 전체, SBS 속보
  - **Nature**: curl 로는 열리지만 macOS URLSession 요청에는 봇 차단 HTML 을 돌려줘 앱에서 쓸 수 없다.

### 앱 코드에서 새 필드 읽기 (`Core/Models.swift` 의 `Source`)
- 저장 필드는 모두 선택값이다: `section`·`lang`·`region`. 예전 상태 파일의 직접 추가 출처도 그대로 읽힌다(시험 있음).
- 기본값을 붙인 읽기 속성:
  - `sectionID`: 없으면 `"ai"`
  - `language`: 없으면 `"en"`
  - `regionCode`: 없으면 `tier == "kr"` 이면 `"kr"`, 아니면 `"intl"`
  - `isDomestic`
- `Resources` enum 은 `Models.swift` 안에 있다. 배정서에 적힌 `Core/Resources.swift` 파일은 따로 없어서 `Source` 정의만 고쳤다.

## 2. 피드 날짜 내성 (G-4)

`Core/FeedParser.swift` 의 `Dates.parse` 가 이제 실제 피드에서 나온 비표준 형식을 읽는다. 표준 형식은 예전과 똑같이 읽는다.

| 형식 | 실제 출처 | 처리 |
|---|---|---|
| `Tue, 13 Oct 2026 16:29:45 +09:00` (RFC 822 + 콜론 시간대) | 매일경제·코리아헤럴드 | 콜론을 빼고 읽음. **예전에는 날짜를 못 읽어 `nil`이었음** |
| `Tue, 13 10 2026 16:00:47 +0900` (숫자 월) | 노컷뉴스 | 요일을 떼고 `dd MM yyyy` 로 읽음 |
| `… EDT` / `EST` / `KST` / `JST` / `UT` | Politico·ESPN 등 | 시간대 이름을 숫자 오프셋으로 바꿔 읽음 |
| 틀린 요일 | — | 요일을 떼고 다시 읽음 |
| `2026-10-13 16:15:42`, `2026.10.13 16:15`, `2026-10-12` (시간대 없음) | AI타임스·Nature dc:date | **한국 시각(Asia/Seoul)** 으로 읽음. 예전에는 시스템 시간대였음 |
| `2026-10-13T16:15:42+0900` (콜론 없는 ISO) | — | 읽음 |
| `2024년 10월 29일 화요일 오후 11:30:00` | JTBC 옛 피드 | 한국 시각으로 읽음 |

`FeedDates.repair` 는 `FeedService.items` 에서 받은 직후 한 번 적용된다.
- **날짜가 없는 글**(한겨레 모든 섹션)은 처음 본 시각을 날짜로 쓴다. 같은 실행 동안에는 바뀌지 않게 기억한다(2만 개가 넘으면 오래된 반을 정리).
- **지금보다 10분 넘게 앞선 시각**은 받은 시각으로 자른다(ESPN 은 서머타임 중에도 `EST` 를 찍어 1시간 앞섬).
- 정정: 조사 때 "매경·코리아헤럴드가 KST 를 +0000 으로 찍어 9시간 미래"라고 적은 것은 **조사용 파이썬 검사기의 오류**였다(`+09:00` 을 UTC 로 읽음). 실제 문제는 콜론 시간대라 위 표처럼 고쳤고, 9시간을 당기는 보정은 넣지 않았다. `docs/research/feeds.json` 은 정정했다. `docs/research/COMPETITIVE.md` 의 G-4 행과 (다)-2 의 같은 문장은 이번 담당 밖이라 고치지 않았다(→ 5).

## 3. 출처 건강 (G-5) · OPML (G-6)

### 출처 건강
- 기록 위치는 `Core/FeedService.swift` 의 `SourceHealth` 와 `SourceHealthBook` 이다.
- `FeedService.items` 가 출처마다 다음을 남긴다.
  - 마지막 성공 시각(304 포함)
  - 마지막 새 글 시각: 피드에서 가장 새 글의 날짜. 날짜 없는 피드는 맨 위 글 id 가 바뀐 시각
  - 연속 실패 수와 마지막 오류
- 저장은 상태 파일과 **따로** `source-health.json` 에 한다(`Store.dir`, 2초 모아 쓰기, 깨지면 빈 기록). 그래서 `Store.swift`·`AppModel` 은 고치지 않았다.
- 표시 규칙:

| 표시 | 조건 |
|---|---|
| 조용함 | 3일 이상 새 글 없음 |
| 멈춤 | 30일 이상 새 글 없음 |
| 글 없음 | 받았는데 0건 |
| 오류 | 연속 3번 실패. 한 번도 성공한 적 없으면 첫 실패부터 |

- 화면은 `UI/SourceTools.swift` 의 `SourceHealthBadge` 다. 켜진 출처 줄에만 보인다.

### OPML
- 형식 처리는 `Core/Channels.swift` 의 `OPML` 이다.
  - 내보내기: 분야별 `<outline>` 묶음으로 만들고, 이름·주소는 XML 이스케이프한다.
  - 가져오기: 안쪽 묶음까지 훑어 `xmlUrl` 만 모으고, 같은 주소는 한 번만 넣는다.
- 화면은 `UI/SourceTools.swift` 의 `OPMLSection`·`OPMLImporter` 다.
  - 가져오기: 피드마다 `AppModel.addChannel`(→ `ChannelResolver`)로 확인해 사용자 출처로 추가한다. 4곳씩 동시에 처리하며 진행 막대와 "n곳 추가 · n곳 이미 있음 · n곳 실패"를 보여 주고, 실패 목록은 펼쳐 볼 수 있다.
  - 내보내기: 켜 둔 출처 전부를 내보낸다.
- `UI/SettingsView.swift` 에는 두 줄만 넣었다.
  - '채널 추가' 구역 아래 `OPMLSection()`
  - 출처 줄의 오류 아이콘 옆 `SourceHealthBadge(source: s)`

## 4. 시험
- 새 파일은 `mac/Tests/DropcapTests/FeedsTests.swift` 다. 날짜 형식(실제 피드 모양), 날짜 다듬기, 건강 상태·저장, OPML 왕복과 다른 앱 OPML 모양, categories·sources 계약(분야 id·필수 필드·분야마다 국내·해외 기본 출처·예전 AI id 유지·예전 출처 해독)을 시험한다.
- `swift test` 는 **79/79 통과**했다.
  - `DROPCAP_LIVE_TESTS=1` 로 실제 피드 120곳을 앱 파서로 받아 날짜까지 읽히는지 확인하는 시험을 포함한 수다. 연속 두 번 통과했다.
  - 그보다 앞선 한 번은 Google AI 가 이름 확인 단계에서 일시적으로 막혀 실패했고, 다시 돌리자 통과했다.

## 5. 남은 것 · 작업자 A 에게 넘길 것
1. **(중요) 기본 켜짐 처리.** `Store.load` 는 상태에 값이 없는 출처를 `defaultOn` 으로 켠다. 그래서 지금 그대로 내보내면 업데이트한 기존 사용자와 새 사용자 모두에게 ★ 출처 39곳(새 30곳)이 바로 켜진다. 온보딩에서 고른 분야의 ★ 출처만 켜도록 A 가 `Store.load`/첫 실행 흐름을 바꿔야 한다. 이 브랜치만 먼저 병합하면 출처가 대량으로 켜지니, A 작업과 함께 병합하거나 그 전에 막아야 한다.
2. `scripts/build.sh` 는 `sources.json` 만 `.app` 에 복사한다. `categories.json` 도 복사해야 설치본에서 읽힌다(담당 밖이라 고치지 않음 — 개발 실행(`swift run`)은 `shared/` 에서 읽혀 문제없음).
3. 설정 '구독' 탭의 '기본 출처'는 아직 `tier` 별(lab/press/kr)로 묶여 있다. 120곳이 세 묶음에 몰리므로 분야별로 다시 묶어야 한다(설정 본체는 A 담당).
4. 직접 추가하거나 OPML 로 들인 출처는 `section` 이 없어 `"ai"` 로 잡힌다(계약상 기본값). 구독할 때 분야를 고르게 하려면 A 쪽 UI 가 필요하다.
5. `docs/research/COMPETITIVE.md` 의 "매경·코리아헤럴드 9시간 미래" 문장을 정정해야 한다(위 2절). 관리자가 정해 주면 고치겠다.
