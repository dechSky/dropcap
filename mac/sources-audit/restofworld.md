# Rest of World (`restofworld`) — 추가 점검

- 종류: feed · 분야 tech · intl · 주소 `https://restofworld.org/feed/latest`
- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: 없음 → 관찰: 유료 없음
- **판정: 실패** · 뺌 — 피드 XML 이 깨짐(사진 주소의 & 를 이스케이프하지 않음) — 앱 파서가 12건 중 1건만 읽음. 본문 추출은 좋음(6천 자)

## 1. 피드로 넘어오는 것

- 앱 피드 읽기: 성공 · 글 1건 · 날짜 1건 · 가장 최근 16.6시간 전 · 사진 0건 · 요약 길이 중앙값 70자

## 2~4. 앱이 얻은 본문 vs 실제 사이트

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |
|---|---|---|---|---|---|
| https://restofworld.org/2026/byd-expands-cargo-ship-ev-exports/?utm_source=rss&utm_medium=rss&utm_campaign=feeds | 빠른 길 0.2초 | 6028 / — (—) | 앱 통과 · 벽 없음 | 0·0·0 | 사이트 403 |

## 5. 번역

영어 기사. 이번 점검에서는 번역을 돌리지 않음(작업자 Translate 몫).

## 6. 필요한 규칙 제안

- 앱 파서가 깨진 & 를 너그럽게 읽게 되면 다시 넣기
