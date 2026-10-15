# Nikkei Asia (`nikkei-asia`) — 추가 점검

- 종류: feed · 분야 economy · intl · 주소 `https://asia.nikkei.com/rss/feed/nar`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: hard → 관찰: hard 로 고침 — 앱이 받은 것은 앞 2~3문단(8~13%), 나머지는 로그인 뒤. Paywall.knownDomains 도 asia.nikkei.com=hard
- **판정: 나쁨(유료)** · 넣음 — 아시아 경제 1차 보도. 하드 유료로 넣고 넣을지는 결정필요

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 50건 · 날짜 50건 · 가장 최근 0.0시간 전 · 사진 0건 · 요약 길이 중앙값 0자
- RDF(RSS 1.0) 피드, 요약·사진 없음

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://asia.nikkei.com/editor-s-picks/interview/singapore-residence-provider-ascott-bets-on-tokyo-station-area | 빠른 길 0.6초 | 584 / 5050 (12%) | 앱 통과 · 벽 없음 | 16·0·0 |  |
| https://asia.nikkei.com/spotlight/my-personal-history/yasuo-stephen-schwarzman-14 | 빠른 길 0.5초 | 381 / 4811 (8%) | 앱 통과 · 벽 없음 | 24·0·0 |  |
| https://asia.nikkei.com/business/markets/equities/chinese-king-of-african-phone-market-transsion-sinks-in-hong-kong-listing | 빠른 길 0.5초 | 512 / 3823 (13%) | 앱 통과 · 벽 없음 | 14·0·0 |  |

완전성 중앙값 12% (사이트 측정이 0 이거나 빗나간 기사는 뺌. 사이트 글자는 본문 영역 선택자 기준이라 ±10% 안팎은 측정 차이)

## 5. 번역

영어 기사. 이번 점검에서는 번역을 돌리지 않음(작업자 Translate 몫).

## 6. 필요한 규칙 제안

- 앱이 막힘으로 판정하지 못함 — paywall=hard 값으로만 표시됨
