# New Scientist (`newscientist`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: metered
- 관찰한 유료 상태: metered + 일부 구독자 전용(사이트는 3문단 뒤 구독 권유) — 앱은 HTML 의 전문을 얻음
- **판정: 좋음** — 앱(URLSession)은 빠른 길로 전문(100~114%)을 얻음. 사진 모음 15장·설명 맞음. 다만 사진 설명 끝에 사진가 이름이 띄어쓰기 없이 붙음.
- 완전성 중앙값(사이트 본문 글 중 앱 본문에 있는 비율): 100% (최저 97%) · 점검일 2026-10-15 · 기사 3건

## 피드로 넘어오는 것

- RSS. 요약 150~230자 + content:encoded(0 또는 3,500~10,000자 — 일부 기사만 전문). media:thumbnail 1350px(좋음). 분야 2~7개 · 기자 있음.
- 링크에 `?utm_campaign=RSS|NSNS&…` 추적 꼬리.
- 주의: 점검 도구(node·curl)는 피드·기사 모두 406 을 받음(브라우저 UA + 비브라우저 TLS 지문 거부). 앱(URLSession)은 피드·기사 모두 정상(앱 점검 모드로 확인).

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| `newscientist.com/article/… ?utm_campaign&utm_content&utm_medium&utm_source` — 최신 | 빠른 길 1.5초 (재현: slow 406) | 3597 / 3694ᴸ (97%) · 사이트가 감춘 본문 7문단을 앱은 얻음 | 없음 | 없음 | 사이트 1 / 우리 0 · 표지 feed 1350×900 | - | 사이트는 구독자 전용(3문단)인데 앱은 전문 |
| `newscientist.com/article/… ?utm_campaign&utm_content&utm_medium&utm_source` — 피드 글 가장 김 | 빠른 길 1.1초 (재현: slow 406) | 9621 / 9645 (100%) · 사이트 글의 100% 있음 | 없음 | 없음 | 사이트 1 / 우리 0 · 표지 feed 1350×900 | - | 완전 |
| `newscientist.com/article/… ?utm_campaign&utm_content&utm_medium&utm_source` — 짧은 글·속보 후보 | 빠른 길 1.0초 (재현: slow 406) | 1950 / 1707 (114%) · 사이트 글의 100% 있음 · 사이트가 감춘 본문 1문단을 앱은 얻음 | 없음 | 날짜 줄 · 사진 설명(사이트와 글자 다름) 4 | 사이트 16 / 우리 15 · 설명 15 · 표지 feed 1350×900 | - | 사진 15·설명 15(설명에 사진가 이름 붙음) |

- 얻은 길·초·표지는 실제 앱(점검 모드)으로 잰 값, 블록 비교는 같은 추출 스크립트를 헤드리스 WebKit 으로 돌린 재현 값(_INTL1.md 의 '재는 법'). ᴸ = 사이트가 유료벽·차단으로 본문을 감춰 기사 머리의 schema.org articleBody 길이를 기준으로 씀.
- 사이트 표시: `article`. 구독자 전용 기사는 3문단 + "Subscribe now", 나머지는 Piano 구독 창. 쿠키 창은 이번엔 안 보임.
- 스크린샷(저장소 밖): newscientist-1.png, newscientist-2.png, newscientist-3.png

## 필요한 규칙(제안)

1. figcaption 끝의 사진가 이름(credit 조각)을 떼거나 " — " 로 띄우기.
2. 첫 기사처럼 ld+json 이 isAccessibleForFree=false 인데 본문이 다 오면 "구독 기사(앱에서는 전문)" 표시 여부 결정 필요(정책).
