# The Verge (`verge-all`)

- 종류: feed · 기본켜짐: 예 · 지금 paywall 값: 없음
- 관찰한 유료 상태: metered(ld isAccessibleForFree=false 2/3, 사이트에 "continue reading with…" 구독 문구) — 지금 값 없음
- **판정: 부분** — 본문은 다 오지만(사이트 대비 125~141% — 넘는 만큼이 군더더기) 3건 모두 기자 소개·"Follow topics and authors…"가 섞이고, 한 건은 페이지 머리(건너뛰기 링크·부제 2번·바이라인·날짜)까지 본문으로.
- 완전성 중앙값(사이트 본문 글 중 앱 본문에 있는 비율): 100% · 점검일 2026-10-15 · 기사 3건

## 피드로 넘어오는 것

- Atom. summary 300~345자 + content 680~1,780자(HTML, 사진 figure 포함 — 짧은 글은 사실상 전문, 사이트의 41~111%). 분야 2~6개 · 기자 있음.

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| `theverge.com/news/1011654/…` — 최신 | 빠른 길 0.3초 | 1170 / 899 (130%) · 사이트 글의 100% 있음 | 없음 | 기자 소개 · 팔로우·알림 권유 | 사이트 0 / 우리 1 · 표지 og 1200×624 | - |  |
| `theverge.com/gadgets/1011227/…` — 피드 글 가장 김 | 빠른 길 0.2초 | 2015 / 1609 (125%) · 사이트 글의 100% 있음 | 없음 | 기자 소개 · 팔로우·알림 권유 2 | 사이트 0 / 우리 2 · 표지 og 1200×624 | - | 쇼핑(딜) 글 — 이메일 신청 칸 문구 |
| `theverge.com/…/1011369/…` — 짧은 글·속보 후보 | 빠른 길 0.3초 | 2351 / 1673 (141%) · 사이트 글의 100% 있음 | 없음 | 건너뛰기 링크 · 부제·요약문 2 · 바이라인 줄 · 날짜 줄 · 기타 문단 2 · 팔로우·알림 권유 2 · 관련 글 목록 | 사이트 0 / 우리 2 · 표지 og 961×497 | 위험: 부제가 두 번 — 같은 문장이 두 번 번역됨 | 페이지 머리까지 섞임 |

- 얻은 길·초·표지는 실제 앱(점검 모드)으로 잰 값, 블록 비교는 같은 추출 스크립트를 헤드리스 WebKit 으로 돌린 재현 값(_INTL1.md 의 '재는 법'). ᴸ = 사이트가 유료벽·차단으로 본문을 감춰 기사 머리의 schema.org articleBody 길이를 기준으로 씀.
- 사이트 표시: `.duet--article--article-body-component` 4~7덩어리. 구독 문구("To continue reading…", "continue reading with…")가 일부 기사에 보이지만 이번 3건은 본문 다 보임. OneTrust 쿠키 창.
- 스크린샷(저장소 밖): verge-all-1.png, verge-all-2.png, verge-all-3.png

## 필요한 규칙(제안)

1. "… is a senior reporter covering …"·"writes about …" 처럼 이름 없이 시작하는 짧은 기자 소개 빼기.
2. "Follow topics and authors from this story…"·"Email (required)" 빼기.
3. "Skip to main content" 가 첫 블록이면 Readability 가 페이지 머리까지 잡은 것 — 제목/부제/바이라인/날짜까지 잘라 내기.
4. sources.json paywall 값 → `metered`.
