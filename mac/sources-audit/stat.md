# STAT (`stat`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: metered
- 관찰한 유료 상태: metered + STAT+ 구독 전용(hard) — 지금 값 metered
- **판정: 부분** — 일반 기사는 사이트가 4문단 뒤 Piano 벽으로 감추지만 HTML 에 전문이 있어 앱은 전문을 얻음. STAT+ 기사는 맛보기 + 구독 권유 7줄인데 길이가 1,500자를 넘어 유료벽 판정(looksBlocked)이 안 걸려 전문처럼 보임.
- 완전성 중앙값(사이트 본문 글 중 앱 본문에 있는 비율): 100% · 점검일 2026-10-15 · 기사 3건

## 피드로 넘어오는 것

- RSS. 요약 120~155자 + content:encoded 590~2,040자(앞 몇 문단, STAT+ 는 맛보기 전부). media 있음 · 분야 4~7개 · 기자 있음.
- 링크에 `?utm_campaign=rss`.

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| `statnews.com/2026/10/14/… ?utm_campaign` — 최신 | 빠른 길 0.2초 | 5580 / 사이트는 748자만 보임(유료벽) · 감춘 22문단을 앱은 얻음 | 없음 | 없음 | 사이트 0 / 우리 0 · 표지 feed 1024×576 | - | 사이트는 4문단(Piano 벽), 앱은 전문 |
| `statnews.com/pharmalot/2026/10/14/… ?utm_campaign` — 피드 글 가장 김 | 빠른 길 0.2초 | 2335 / 2008 (116%) · 사이트 글의 100% 있음 | 본문 대부분(구독 전용) | 부제·요약문 · 구독·뉴스레터 권유 6 | 사이트 0 / 우리 1 · 표지 feed 1024×576 | - | STAT+ 맛보기 — 앱은 유료벽으로 못 알아봄 |
| `statnews.com/2026/10/14/… ?utm_campaign` — 짧은 글·속보 후보 | 빠른 길 0.2초 | 6831 / 사이트는 1537자만 보임(유료벽) · 감춘 15문단을 앱은 얻음 | 없음 | 없음 | 사이트 0 / 우리 0 · 표지 feed 1024×576 | - | 사이트는 4문단, 앱은 전문(오피니언) |

- 얻은 길·초·표지는 실제 앱(점검 모드)으로 잰 값, 블록 비교는 같은 추출 스크립트를 헤드리스 WebKit 으로 돌린 재현 값(_INTL1.md 의 '재는 법'). ᴸ = 사이트가 유료벽·차단으로 본문을 감춰 기사 머리의 schema.org articleBody 길이를 기준으로 씀.
- 사이트 표시: `.entry-content.the-content`. 일반 기사: 4문단 뒤 Piano(`#piano-breaker`) 벽. STAT+: "This article is exclusive to STAT+ subscribers". OneTrust 쿠키 창.
- 스크린샷(저장소 밖): stat-1.png, stat-2.png, stat-3.png

## 필요한 규칙(제안)

1. Paywall.looksBlocked: "exclusive to stat+ subscribers"·"to read the rest of this story subscribe" 같은 강한 문구는 1,500자 기준 없이 판정(지금은 맛보기+권유가 2,335자라 통과).
2. 맛보기 기사의 "Already have an account? Log in"·"Unlock this article…"·"STAT+ Exclusive Story" 줄 빼기.
3. sources.json paywall: `metered` 유지 + 피드 분야/주소에 STAT+ 표시가 있으면 그 기사만 hard 로.
