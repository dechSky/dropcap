# South China Morning Post (`scmp`) — 추가 점검

- 종류: feed · 분야 world · intl · 주소 `https://www.scmp.com/rss/91/feed`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: metered → 관찰: metered(사이트는 열림 5.7~14.6천 자) — 앱 빠른 길은 앞 4문단만(5~11%)
- **판정: 나쁨** · 뺌 — 나머지 본문을 스크립트로 붙이는 페이지라 빠른 길이 일부만 얻고도 '글이 많은 페이지'로 보고 멈춤. 느린 길 강제 규칙이 생기면 다시 보기

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 50건 · 날짜 50건 · 가장 최근 0.4시간 전 · 사진 50건 · 요약 길이 중앙값 300자

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://www.scmp.com/news/hong-kong/society/article/3370901/hong-kong-teen-makes-cents-finance-taps-ai-tackle-economic-inequality?utm_source=rss_feed | 빠른 길 0.6초 | 904 / 12758 (7%) | 앱 통과 · 벽 없음 | 71·3·8 |  |
| https://www.scmp.com/news/asia/australasia/article/3370928/hidden-cameras-found-womens-showers-australian-navy-ship?utm_source=rss_feed | 빠른 길 0.6초 | 638 / 5757 (11%) | 앱 통과 · 벽 없음 | 26·10·12 |  |
| https://www.scmp.com/week-asia/people/article/3370927/south-koreas-offender-tracking-under-scrutiny-after-stabbing-spree-exposes-serious-gaps?utm_source=rss_feed | 빠른 길 0.6초 | 790 / 14589 (5%) | 앱 통과 · 벽 없음 | 81·5·9 |  |

완전성 중앙값 7% (사이트 측정이 0 이거나 빗나간 기사는 뺌. 사이트 글자는 본문 영역 선택자 기준이라 ±10% 안팎은 측정 차이)

## 5. 번역

영어 기사. 이번 점검에서는 번역을 돌리지 않음(작업자 Translate 몫).

## 6. 필요한 규칙 제안

- 빠른 길 결과가 피드 요약보다 조금 긴 정도면 느린 길로 넘기는 규칙(또는 출처별 '느린 길' 표시)
