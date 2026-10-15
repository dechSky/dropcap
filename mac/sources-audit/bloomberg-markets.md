# Bloomberg Markets (`bloomberg-markets`) — 추가 점검

- 종류: feed · 분야 economy · intl · 주소 `https://feeds.bloomberg.com/markets/news.rss`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: hard → 관찰: hard 맞음 — 앱 빠른 길이 받은 것은 첫 문단·요점 목록(0.5~1.2천 자), 헤드리스 403
- **판정: 나쁨(유료)** · 넣음 — 하드 유료·봇 차단. 영상·뉴스레터 글이 섞임. paywall=hard 로 넣음, 넣을지는 결정필요

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 20건 · 날짜 20건 · 가장 최근 0.1시간 전 · 사진 0건 · 요약 길이 중앙값 207자
- 피드에 /news/videos/ · /news/newsletters/ 글이 섞임. 사진 없음

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://www.bloomberg.com/news/newsletters/2026-10-15/india-s-bond-market-shows-bets-building-for-more-rbi-rate-hikes | 빠른 길 1.3초 | 473 / — (—) | 앱 통과 · 벽 없음 | —·—·— | 사이트 403 |
| https://www.bloomberg.com/news/videos/2026-10-15/singapore-dpm-must-work-faster-to-vie-with-wealth-hubs-video | 빠른 길 0.9초 | 1196 / — (—) | 앱 통과 · 벽 없음 | —·—·— | 사이트 403 |
| https://www.bloomberg.com/news/videos/2026-10-15/imf-apac-chief-warns-of-rising-market-risks-video | 빠른 길 2.4초 | 963 / — (—) | 앱 통과 · 벽 없음 | —·—·— | 사이트 403 |

## 5. 번역

영어 기사. 이번 점검에서는 번역을 돌리지 않음(작업자 Translate 몫).

## 6. 필요한 규칙 제안

- 앱이 막힘으로 판정하지 못함(Paywall.looksBlocked 거짓) — paywall=hard 값으로만 표시됨
