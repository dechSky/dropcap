# 한국일보 (`hankook`) — 추가 점검

- 종류: sitemap · 분야 top · kr · 주소 `https://www.hankookilbo.com/sitemap/latest-articles` · 거르기 `^https:\/\/www\.hankookilbo\.com\/news\/article\/A\d+$`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: 없음 → 관찰: 유료 없음
- **판정: 좋음** · 넣음 — 중도 종합지. RSS 없음, 최근 기사 사이트맵을 씀. 본문 100%

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 799건 · 날짜 799건 · 가장 최근 0.0시간 전 · 사진 0건 · 요약 길이 중앙값 0자
- 사이트맵에 lastmod 가 없고 news:publication_date 만 있음 — 앱은 lastmod 만 읽어서 날짜가 없음(FeedDates.repair 가 처음 본 시각으로 채움). 하루 약 230건

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://www.hankookilbo.com/news/article/A2026101510530000823 | 빠른 길 0.7초 | 1461 / 1462 (100%) | 앱 통과 · 벽 없음 | 8·3·1 |  |
| https://www.hankookilbo.com/news/article/A2026101509180001511 | 빠른 길 0.5초 | 1236 / 1238 (100%) | 앱 통과 · 벽 없음 | 6·1·1 |  |
| https://www.hankookilbo.com/news/article/A2026101508570001573 | 빠른 길 0.4초 | 896 / 896 (100%) | 앱 통과 · 벽 없음 | 6·1·1 |  |

완전성 중앙값 100% (사이트 측정이 0 이거나 빗나간 기사는 뺌. 사이트 글자는 본문 영역 선택자 기준이라 ±10% 안팎은 측정 차이)

## 5. 번역

국내 출처 — 해당 없음

## 6. 필요한 규칙 제안

- 앱 parseSitemap 이 news:publication_date 도 읽게(한국일보·문화일보 날짜) — 앱 코드 담당에게 제안
