# 한겨레 정치 (`hani-politics`) — 추가 점검

- 종류: feed · 분야 politics · kr · 주소 `https://www.hani.co.kr/rss/politics/`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: 없음 → 관찰: 유료 없음
- **판정: 좋음** · 넣음 — 기존 한겨레 출처의 빠진 분야(정치). 본문 113~123%(앱이 사진 설명까지 셈)

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 30건 · 날짜 30건 · 가장 최근 0.0시간 전 · 사진 30건 · 요약 길이 중앙값 0자
- 한겨레 다른 분야처럼 글 날짜가 없음(FeedDates.repair). 요약도 없음

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://www.hani.co.kr/arti/politics/politics_general/1282493.html | 빠른 길 0.3초 | 834 / 736 (113%) | 앱 통과 · 벽 없음 | 7·0·1 |  |
| https://www.hani.co.kr/arti/politics/bluehouse/1282414.html | 빠른 길 0.3초 | 965 / 850 (114%) | 앱 통과 · 벽 없음 | 6·0·1 |  |
| https://www.hani.co.kr/arti/politics/politics_general/1282491.html | 빠른 길 0.4초 | 1027 / 838 (123%) | 앱 통과 · 벽 없음 | 6·0·1 |  |

완전성 중앙값 114% (사이트 측정이 0 이거나 빗나간 기사는 뺌. 사이트 글자는 본문 영역 선택자 기준이라 ±10% 안팎은 측정 차이)

## 5. 번역

국내 출처 — 해당 없음

## 6. 필요한 규칙 제안

- mac LiveSourceDatesTests 의 '날짜 없는 피드' 목록에 hani-politics·hani-economy 를 더해야 함(시험 파일 담당에게 인계)
