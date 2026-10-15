# ProPublica (`propublica`) — 추가 점검

- 종류: feed · 분야 society · intl · 주소 `https://www.propublica.org/feeds/propublica/main`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: 없음 → 관찰: 유료 없음
- **판정: 좋음** · 넣음 — 탐사보도 비영리(퓰리처 다수). 긴 기사(4~28천 자)를 100~117% 로 얻음. 하루 2건 남짓

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 20건 · 날짜 20건 · 가장 최근 14.9시간 전 · 사진 20건 · 요약 길이 중앙값 135자

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://www.propublica.org/article/domestic-violence-immigrant-victims-ice-detention | 빠른 길 0.7초 | 28476 / 28476 (100%) | 앱 통과 · 벽 없음 | 102·1·5 |  |
| https://www.propublica.org/article/ken-paxton-travel-security-costs | 빠른 길 0.5초 | 13192 / 12951 (102%) | 앱 통과 · 벽 없음 | 50·2·1 |  |
| https://www.propublica.org/article/sports-betting-problem-gambling-draftkings-fanduel | 빠른 길 0.6초 | 4308 / 3670 (117%) | 앱 통과 · 벽 없음 | 13·0·1 |  |

완전성 중앙값 102% (사이트 측정이 0 이거나 빗나간 기사는 뺌. 사이트 글자는 본문 영역 선택자 기준이라 ±10% 안팎은 측정 차이)

## 5. 번역

영어 기사. 이번 점검에서는 번역을 돌리지 않음(작업자 Translate 몫).

## 6. 필요한 규칙 제안

- 없음
