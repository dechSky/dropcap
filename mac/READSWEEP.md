# 읽기 창 본문 성공률 전수 점검 (2026-10-14)

"기사 읽기가 안 된다"는 보고의 원인 후보 ①(사이트별 본문 추출 실패)을 숫자로 확인하고 고친 기록.
②(매거진 표지 클릭 무반응)은 7d254fc, ③(Vision 동시 실행으로 앱 전체 비동기 정지)은 작업자 F 의 PhotoQuality.scoreAsync 가 맡는다.

## 한 줄 결론

**본문 추출은 원래도 99% 성공(236/238)이었다.** 사용자가 겪은 "안 열림"은 ①보다 ②·③ 쪽일 가능성이 크다.
①에서 찾은 것은 실패보다 **느림(최대 17.7초)·잘못된 안내·표지 사진** 문제였고, 그것을 고쳤다.

## 전·후 (같은 238건을 다시 돌림)

| | 전(before) | 후(after) |
|---|---|---|
| 성공 | 236/238 (99%) | **237/238 (100%)** |
| 국내 / 해외 | 137/138 · 99/100 | 138/138 · 99/100 |
| 빠른 길(HTML 만) / 실린 본문 자료 / 느린 길(웹 보기) | 214 / – / 22 | 215 / **6** / 16 |
| 미리 받기(스크립트 없음)로도 되는 기사 | 214 | **221** |
| 걸린 시간 중앙값 · 90% · 최대 | 0.40초 · 1.68초 · **17.7초** | 0.43초 · 1.37초 · 6.8초 |
| 5초 넘음 | 4건 | 4건(WSJ·MarketWatch) → FeedService 고친 뒤 0건(아래) |
| 표지 사진 있음 | 233 | 236 |
| 표지 의심(작음·못 받음·잘못된 주소) | 16+ (전 측정은 크기를 2배로 잼 — 아래) | 3 (둘은 연합뉴스가 두 기사에 같은 자료 사진을 쓴 것) |

- 대상: `shared/sources.json` 기본 출처 120곳(국내 70·해외 50) 각 최신 2건. MBC 주요 뉴스 피드는 이날 기사를 주지 않아 119곳 238건.
- 표 전체(기사별 결과·초·길·글자·문단·그림·까닭·표지): [`readsweep/sweep-before.md`](readsweep/sweep-before.md), [`readsweep/sweep-after.md`](readsweep/sweep-after.md).

## 찾은 것과 고친 것

| # | 찾은 것 | 영향 | 고침 |
|---|---|---|---|
| 1 | 조선일보(Arc Publishing)는 HTML 에 본문 글이 없고 스크립트가 그린다(보이는 글 17~48자) | 매번 느린 길(웹 보기) 2초 남짓, 미리 받기에서는 늘 실패 | `Reader/EmbeddedArticle.swift`: HTML 에 실려 오는 본문 자료를 읽는다 — Arc `Fusion.globalContent` 의 content_elements(문단·소제목·사진+설명·목록·인용), 없으면 schema.org `articleBody`(ld+json·@graph). 빠른 길이 못 찾을 때만. 조선 6건 2.0초 → 0.6초, 미리 받기에서도 열림 |
| 2 | 실패 화면이 까닭과 상관없이 늘 "유료 기사·차단 등" | BBC 영상 페이지(글 68자)에서 엉뚱한 안내 | `ReaderFailure`(차단·없어짐·글 없음·연결 문제·모름)를 기록(`PreparedArticle.failure`)해 맞는 안내. 연결 문제·모름이면 '다시 시도' 단추. 영상 페이지는 "본문 글이 거의 없는 기사입니다(영상·사진 기사 등)" 확인(화면) |
| 3 | 없어진 페이지(404·410)도 느린 길 15초를 다 기다림 | 지워진 기사를 열면 17초 뒤 실패 | 404·410 이면 느린 길을 건너뜀(아래 FeedService 고침과 함께 17초 → 3초 안) |
| 4 | 피드 사진이 작은 미리보기: BBC 240px·가디언 140px·코리아헤럴드 300px·연합 일부 357px | 읽기 창 맨 위 표지가 흐림 | `Reader/CoverPick.swift` + `findCover`: 피드 사진이 가로 400px 미만이거나 못 받으면 기사 머리 대표 사진(og:image)으로. 31건이 큰 사진으로 바뀜(예: BBC 240 → 1200, 가디언 → 1200×630) |
| 5 | Politico(8.5MB)·NPR(15MB)은 피드에 원본 사진을 실어 8MB 상한(S-12)에 걸려 못 받음 | 표지가 깨진 자리로 남음 | 4 와 같이 og:image 로 대체, 대체도 없으면 깨진 자리를 지움 |
| 6 | og:image 찾기 정규식이 `og:image:type`(content 먼저 쓴 꼴)에 걸림 | DW 표지 주소가 `…/image/jpeg`(404) | `CoverPick.ogImage`: `<meta>` 를 한 번 훑어 하나씩 떼어 속성을 읽음(속성 순서·따옴표 꼴 무관, 정규식 되풀이 훑기 없음). `og:image` → `og:image:url` → `secure_url` → `twitter:image` 순 |
| 7 | 표지와 같은 사진을 본문에서 뺄 때 그 사진 설명은 남음 | 사진 없이 설명 한 줄만 덩그러니(조선 등 figure 꼴) | 뺀 그림 바로 뒤의 사진 설명도 함께 뺌 |
| 8 | 맥의 '보이는 글자 세기'가 아직 정규식(윈도우는 e9e1469 에서 고침) | 닫히지 않은 `<script` 가 많은 페이지에서 시간 폭증 가능 | 윈도우와 같은 한 번 훑기로 |

글이 짧게 나온 기사(전자신문 103자, 노컷 285자, SBS 333자 등)는 원문을 받아 대조해 보니 **실제로 짧은 기사**(포토·영상 뉴스)였다 — 잘림 아님.

## FeedService 고침(관리자 허락, 2곳) 뒤

extras2(S-12, 1844c31)에서 내가 만든 회귀: 2xx 가 아닌 응답은 본문을 받지 않으려 전송을 끊는데, 끊은 전송은 **연결 측정값(접속 IP)이 오지 않는다**(작은 실험으로 확인: 끝까지 읽으면 0.1~0.4초에 옴, 끊으면 안 옴). 그래서 2초 기다린 뒤 `HTTP 403` 대신 `접속 IP 확인 안 됨` 이 되어, 읽기 창이 거절(401·403·429)도 없어진 페이지(404)도 알지 못하고 느린 길을 15초 한도로 돌았다.

- `FeedService.settle`: 2xx 가 아니면 본문을 쓰지 않으므로 **IP 판정 전에** `FeedError.http(code)` — 2xx 는 예전처럼 IP 확인 뒤에만 씀.
- `FeedService.ogImage` 는 `CoverPick.ogImage` 를 부른다(og:image:type 오인 — 매거진 표지에도 효과).
- 그러자 드러난 것: NYT 는 빠른 길만 403 이고 느린 길(웹 보기)은 대개 1.4~2.1초에 열린다. 거절 사이트의 느린 길 한도 6초를 넘긴 기사 **하나**가 실패하자 NYT 전체가 '막힌 사이트'로 기억되어 뒤 기사들이 모두 바로 실패했다. → 막힌 사이트 기억은 **느린 길로 열린 적이 없고 거절 뒤 두 번 이어서 못 열 때만**, 열린 적이 있는 사이트는 한도 10초(`slowWait`·`noteSlow`).

같은 기사로 다시 잰 것(영향받은 15곳 30건):

| | 고치기 전(after) | FeedService 고친 뒤 |
|---|---|---|
| WSJ Markets 2건 | 6.8 · 5.9초 | 3.3 · 4.5초 |
| MarketWatch 2건 | 5.4 · 5.1초 | 2.7 · 3.3초 |
| NYT(1차 다시 잼) | 3.3~4.3초(2초가 IP 기다림) | 1.4~2.1초 |
| 없어진 기사(경향 404) | 17.2초 뒤 "본문을 추리지 못했습니다" | 3초 안에 "기사 페이지가 없어졌습니다" |
| 경향·DW | 0.6~3.0초 성공 | 같음 |

- NYT 는 DataDome 봇 막기를 쓴다. 이날 시험으로 같은 기사를 여러 번 받자 두 번째 다시 잴 때는 이 Mac 에 확인 문제(captcha-delivery)를 내기 시작해 느린 길도 6초 넘게 열리지 않았다 — 이때는 두 번 실패 뒤 '막힌 사이트' 안내로 바로 넘어가는 것이 맞는 동작. 보통 사용자(기사 몇 건)는 첫 번째 다시 잼처럼 1~2초에 열릴 것으로 본다.
- 이 Mac 에서 경향신문 첫 요청 하나가 200 인데도 측정값을 2초 안에 못 받아 실패를 한 번 냈다(뒤 요청은 모두 0.6초 성공, 다시 돌리면 0.7초 성공). 드문 일이라 그대로 둠.

## 시험

- `swift test` 224개 통과. 새 시험(`Tests/DropcapTests/ReadSweepTests.swift`):
  - `ReadSweepTests`: 실패 까닭 분류, 표지 의심 판정, 표 만들기(| 바꿈), 같은 출처 공용 사진 표시, 보이는 글자 세기(닫히지 않은 `<script` 4만 개에도 2초 안), og:image 찾기(DW 꼴·대문자·따옴표 없음·data-content·javascript: 거부·닫히지 않은 `<meta` 6천 개), 실패 종류.
  - `FeedServiceFixTests`: 401·403·404·429·500 은 IP 판정을 부르지 않고 그 코드로, 304, 2xx 는 IP 판정·내부망이면 막음, 로컬 시험 서버의 DW 꼴 머리에서 og:image.
  - `BlockedHostTests`: 열린 적 있는 사이트는 실패해도 막지 않고 한도 10초, 거절 뒤 두 번 못 열면 막음(거절 아닌 실패는 안 셈).
  - `EmbeddedArticleTests`: Fusion(소제목·사진+설명·목록·raw_html 무시·javascript: 사진 거부·문자 참조), ld+json @graph·여러 저자·숫자 문자 참조, 짧거나 깨진 자료는 nil, 문자열 속 괄호를 건너뛰는 괄호 맞추기.
- 화면(시험 폴더 `DROPCAP_DATA_DIR`): BBC 영상 페이지 실패 안내, 없어진 기사(404) 안내, 조선 기사(실린 본문 자료 1.3초, 표지·본문, 표지와 같은 사진의 설명 빠짐).

## 다시 돌리는 법

```sh
cd mac && swift build
D=$(mktemp -d); OUT=$(mktemp -d)
DROPCAP_DATA_DIR=$D DROPCAP_TEST_READSWEEP=$OUT DROPCAP_TEST_READSWEEP_LABEL=before .build/debug/Dropcap   # 4~5분, 끝나면 앱이 닫힘
# 고친 뒤 같은 기사로:
DROPCAP_DATA_DIR=$(mktemp -d) DROPCAP_TEST_READSWEEP=$OUT DROPCAP_TEST_READSWEEP_LABEL=after \
  DROPCAP_TEST_READSWEEP_REPLAY=$OUT/sweep-before.json .build/debug/Dropcap
```

- `DROPCAP_TEST_READSWEEP_N`(출처마다 몇 건, 기본 2) · `DROPCAP_TEST_READSWEEP_ONLY=<출처 id,…>`(그 출처만).
- 기사마다 `ArticleExtractor().extract(allowScripts: true)`(사용자가 연 것과 같은 길)를 차례로 — 시간이 섞이지 않게 한 번에 하나. 표지는 읽기 창 `findCover` 와 같은 순서.
- 추출 과정은 `ExtractTrace`(길·거절 코드·받기 실패 까닭·보이는 글자 수·짧아서 버린 길이·느린 길을 건너뛴 까닭·초)로 남는다.
- 주의: 전(before) 표의 표지 크기는 `NSImage` 표현의 pixelsWide 로 재어 일부(BBC 등)가 실제의 2배로 적혔다. 후(after)는 실제 픽셀로 잼.
