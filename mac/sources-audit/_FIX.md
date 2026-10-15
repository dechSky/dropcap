# sources-fix — 출처 목록 바로잡기

> 2026-10-15 · 작업자 Sources · 브랜치 `wt/sources-fix`. 근거는 매체별 분석(_KR1·_KR2·_INTL1·_INTL2.md)과 사용자 결정. 148곳 → **147곳(국내 82 · 해외 65)**.

## 기본 켜짐(사용자 결정)

| 출처 | 바꿈 | 근거 |
|---|---|---|
| `joongang` 중앙일보 | defaultOn → true | 사용자 결정(추천대로). 사이트맵이라 발행 시각은 아래 사이트맵 날짜 읽기로 정확 |
| `ieee-spectrum` IEEE Spectrum | defaultOn → true | 사용자 결정 |
| `propublica` ProPublica | defaultOn → true | 사용자 결정 |
| `reuters` | 그대로 끔 | 사용자 결정 |
| FT·Economist·Bloomberg 2·Nikkei | 그대로(끔·hard) | 사용자 결정 |

켜기는 저장된 `enabled` 값이 없는 출처에만 적용된다(Store.prepare). 이미 148곳 판을 받아 이 세 곳이 '꺼짐'으로 저장된 사용자는 그대로 꺼져 있다 — 사용자가 고른 값을 덮지 않기 위함.

## 유료 표시(paywall)

| 출처 | 전 → 후 | 근거 한 줄 |
|---|---|---|
| `verge` · `verge-all` | 없음 → metered | 구독 문(Zephr)·ld `isAccessibleForFree=false` 2/3 (INTL1·INTL2) |
| `nyt-*` 6곳 | metered → hard | 앱은 403 으로 한 건도 못 읽고 사이트도 구독 문 (INTL2, 분석 제안) |
| `marketwatch` | metered → hard | 앱 3/3 차단(401, DataDome), 사이트도 확인 화면만 (INTL1) |
| `mit-tr` | 없음 → metered | Piano 구독 팝업, 본문은 HTML·피드에 다 있음 (INTL1) |
| `politico` | 없음 → metered | 일반 기사도 사이트에서 앞 4문단만(ld false) (INTL1) |
| `stat` | metered 유지 | 일반 기사는 metered 가 맞음. STAT+ 만 hard — 기사 단위 판정은 읽기 창/유료 판정 몫이라 여기서 안 바꿈 |
| `hk-finance` · `hk-it` · `hk-realestate` · `hk-world` | 없음 → metered | 한경 프리미엄9(`articlePayment="Y"`) 기사는 서버가 맛보기만 보냄 — 일부 유료 (KR1·KR2) |
| `hk-economy` · `hk-politics` | 그대로(없음) | 이번 표본에 프리미엄9 없음, 전문 공개 관찰 (KR2) |

## 피드 고장

| 출처 | 바꿈 | 이유 |
|---|---|---|
| `nocut-it` | 주소 `category/it.xml` → `category/industry.xml`, 이름 '노컷뉴스 산업' | it.xml 은 2023-05-31 에 멈춤. 노컷에 IT/과학 피드가 따로 없고(science·tech 주소는 빈 응답), 산업 피드는 살아 있고 삼성·SKT·네이버 등 IT 비중이 높아 같은 분야(tech)로 둠. 원래 기본 꺼짐이라 대신 켤 출처 없음. id 는 사용자 설정 보존을 위해 그대로 |
| `mbc-top` | **뺌** | 라디오 뉴스 mp3 목록뿐(기사 링크 0건). MBC 뉴스는 다른 RSS·사이트맵 주소가 모두 사이트 첫 화면으로 옮겨짐 — 살아 있는 대체 없음. 원래 기본 꺼짐이라 대신 켤 출처 없음. 저장된 `enabled["mbc-top"]` 은 목록에 없는 출처라 쓰이지 않음 |

## 조선일보 전체 — 일본어판 섞임

- `chosun-all`: 피드(`/arc/outboundfeeds/rss/`, 100건 중 43~45건이 `/jp/`) → **뉴스 사이트맵**(`/arc/outboundfeeds/news-sitemap/`)으로 바꾸고 `match` 로 한국어 분야만 받음: politics·national·economy·international·culture-life·opinion·sports·entertainments·special·investigation·science·medical. `/jp/`·`/english/` 는 걸러짐(오늘 사이트맵 100건 중 36건이 한국어 기사로 맞음). lang 은 ko 그대로 맞음.
- 피드 쪽에 거르기 규칙을 새로 두는 것보다 이미 있는 사이트맵 `match`(앱에 든 출처 것만 쓰는 안전 장치 포함)를 쓰는 편이 세 판 코드 변경이 없다. 제목은 사이트맵 출처와 같이 본문에서 채움(fillTitle).

## 사이트맵 날짜(SrcAdd 인계)

- 맥 `FeedParser.parseSitemap` · 윈도우 `FeedParser.ParseSitemap` · 리눅스 `feed_parser::parse_sitemap`: `news:news/news:publication_date` 를 먼저, 없으면 `lastmod`. 한국일보(826/826)·문화일보(852/852)는 발행 시각만 있어 지금까지 '처음 본 시각'으로 채워졌다. 중앙·조선은 둘 다 있고 발행 시각을 씀(고친 시각보다 정확).
- 시험: 세 판에 같은 꼴 `sitemapReadsNewsPublicationDate`(발행 시각만 · 둘 다 · lastmod 만).
- 맥 `LiveSourceDatesTests` 의 날짜 없는 목록에 `hani-politics`·`hani-economy` 추가.

## 시험 고침(바뀐 값 따라)

- 세 판 `sourcesJSONMarksKnownPaywalls`: nyt-* → hard, verge → metered.
- 윈도우 `PaywallTests`·`MenuSettingsExtrasTests` 의 '무료 출처' 예를 verge → ars(무료)로.

## 남은 것(담당 밖)

- README.md · docs/README.md 의 '기본 출처 148곳(국내 83 · 해외 65)' → **147곳(국내 82 · 해외 65)** 로 고쳐야 함(문서 담당).
- STAT+ 기사 단위 hard, 한경 프리미엄9 기사 단위 '맛보기' 표시는 유료 판정(Paywall) 몫.
