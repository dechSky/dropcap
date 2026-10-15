# MarketWatch (`marketwatch`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: metered
- 관찰한 유료 상태: 차단(앱에서 못 엶) — DataDome 봇 막기, 빠른 길 401 · 느린 길 6초 뒤 실패
- **판정: 나쁨** — 3건 모두 차단(401, captcha-delivery). 사이트도 헤드리스로는 확인 문제만 보임. 피드 요약도 짧아(25~130자) 읽기 창이 거의 빈 화면.
- 완전성 중앙값(사이트 본문 글 중 앱 본문에 있는 비율): - · 점검일 2026-10-15 · 기사 3건

## 피드로 넘어오는 것

- RSS(Dow Jones). 요약 25~130자 · content 12~32자 · media:content(크기 없음) · 기자 있음 · 분야 없음.
- 링크에 `?mod=mw_rss_topstories` 추적 꼬리.

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| `marketwatch.com/story/… ?mod` — 최신 | 실패(차단 401) | 사이트 차단 | 없음 | 없음 | - · 표지 feed 1280×853 | - | 차단 401 |
| `marketwatch.com/story/… ?mod` — 피드 글 가장 김 | 실패(차단 401) | 사이트 차단 | 없음 | 없음 | - · 표지 feed 1280×853 | - | 차단 401 |
| `marketwatch.com/story/… ?mod` — 짧은 글·속보 후보 | 실패(차단 401) | 사이트 차단 | 없음 | 없음 | - · 표지 feed 1280×720 | - | 차단 401 |

- 얻은 길·초·표지는 실제 앱(점검 모드)으로 잰 값, 블록 비교는 같은 추출 스크립트를 헤드리스 WebKit 으로 돌린 재현 값(_INTL1.md 의 '재는 법'). ᴸ = 사이트가 유료벽·차단으로 본문을 감춰 기사 머리의 schema.org articleBody 길이를 기준으로 씀.
- 사이트 표시: 차단 — 헤드리스 Chromium·WebKit 모두 401 + DataDome 확인 문제(iframe captcha-delivery). 사람 브라우저에서는 metered 유료벽(Barron's·WSJ 계열).
- 스크린샷(저장소 밖): marketwatch-1.png, marketwatch-2.png, marketwatch-3.png

## 필요한 규칙(제안)

1. sources.json paywall 을 `metered` → `hard` 로(또는 "앱에서 열리지 않음" 표시) — 지금은 "일부 유료"라 열어 보고 6초 기다린 뒤 실패.
2. 차단 사이트 기억(blockedHosts)을 이 출처는 처음부터 켜 두기: 느린 길 6초를 건너뛰고 피드 요약 + 원문 열기.
