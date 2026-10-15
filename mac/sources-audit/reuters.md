# Reuters (`reuters`) — 추가 점검

- 종류: sitemap · 분야 world · intl · 주소 `https://www.reuters.com/arc/outboundfeeds/news-sitemap/?outputType=xml` · 거르기 `^https:\/\/www\.reuters\.com\/(world|business|markets|technology|sustainability|science|legal)\/[a-z0-9-]+(\/[a-z0-9-]+)?-\d{4}-\d{2}-\d{2}\/$`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: 없음 → 관찰: 유료벽 없음(앱 느린 길로 본문 전체). 헤드리스 Chromium 은 401(봇 차단)이라 사이트 글자 수는 못 잼
- **판정: 좋음** · 넣음 — 세계 3대 통신사. 공식 RSS 가 없어 공개 뉴스 사이트맵(구글 뉴스용, 최근 이틀·lastmod 있음)을 씀. 앱 느린 길로 2.8~5.4천 자

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 39건 · 날짜 39건 · 가장 최근 0.1시간 전 · 사진 0건 · 요약 길이 중앙값 0자
- 사이트맵이라 제목·요약·사진은 앱이 기사 페이지를 한 번 받아 채움(fillTitle). 거르기 정규식으로 world·business·markets·technology·sustainability·science·legal 기사만(영상·사진·라이브 뺌). 하루 약 200여 건

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://www.reuters.com/world/middle-east/failure-activate-hormuz-fertilizer-plan-could-trigger-food-crisis-un-official-2026-10-14/ | 느린 길(빠른 길 401) 4.9초 | 5376 / — (—) | 앱 통과 · 벽 없음 | 0·0·0 | 사이트 401 |
| https://www.reuters.com/world/asia-pacific/australia-employment-slides-39300-september-jobless-47-2026-10-15/ | 느린 길(빠른 길 401) 4.3초 | 3190 / — (—) | 앱 통과 · 벽 없음 | 0·0·0 | 사이트 401 |
| https://www.reuters.com/world/india/indian-shares-set-open-lower-hot-us-inflation-raises-rate-worries-2026-10-15/ | 느린 길(빠른 길 401) 4.6초 | 2784 / — (—) | 앱 통과 · 벽 없음 | 0·0·0 | 사이트 401 |

## 5. 번역

영어 기사. 이번 점검에서는 번역을 돌리지 않음(작업자 Translate 몫).

## 6. 필요한 규칙 제안

- 빠른 길은 401/403 — 느린 길이 늘 필요(기사당 3~5초). 출처 규칙에 '바로 느린 길' 표시가 있으면 빠른 길 시도를 건너뛰어 요청을 줄일 수 있음
- fillTitle 의 꼬리 떼기(' | Reuters')는 지금 Anthropic 만 — og:title 은 깨끗해서 당장은 필요 없음
