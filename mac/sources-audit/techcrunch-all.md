# TechCrunch (`techcrunch-all`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: 없음
- 관찰한 유료 상태: 없음(무료)
- **판정: 부분** — 글은 103~119%(넘는 만큼이 군더더기). 3건 모두 제휴 고지, 2건은 기자 소개·연락처(“[email protected]” 꼴로 깨진 메일 주소)가 끝에 섞임.
- 완전성 중앙값(사이트 본문 글 중 앱 본문에 있는 비율): 100% · 점검일 2026-10-15 · 기사 3건

## 피드로 넘어오는 것

- RSS. 요약 85~390자(맨 글자). 본문·사진(media) 없음 → og:image. 분야 2~7개 · 기자 있음.

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| `techcrunch.com/2026/10/14/…` — 최신 | 빠른 길 0.3초 | 3270 / 2743 (119%) · 사이트 글의 100% 있음 | 없음 | 제휴 고지 · 기자 소개 · 기자 연락처 | 사이트 1 / 우리 1 · 설명 1 · 표지 og 1200×800 | - | 끝 3줄 군더더기 |
| `techcrunch.com/2026/10/14/…` — 피드 글 가장 김 | 빠른 길 0.2초 | 5061 / 4933 (103%) · 사이트 글의 100% 있음 | 없음 | 제휴 고지 | 사이트 0 / 우리 0 · 표지 og 1200×843 | - | 끝 제휴 고지 |
| `techcrunch.com/2026/10/14/…` — 짧은 글·속보 후보 | 빠른 길 0.2초 | 3102 / 2703 (115%) · 사이트 글의 100% 있음 | 없음 | 제휴 고지 · 기타 문단 · 기자 연락처 | 사이트 0 / 우리 0 · 표지 og 1200×800 | 위험: "[email protected]" 같은 깨진 조각이 번역됨 | 끝 3줄 군더더기 |

- 얻은 길·초·표지는 실제 앱(점검 모드)으로 잰 값, 블록 비교는 같은 추출 스크립트를 헤드리스 WebKit 으로 돌린 재현 값(_INTL1.md 의 '재는 법'). ᴸ = 사이트가 유료벽·차단으로 본문을 감춰 기사 머리의 schema.org articleBody 길이를 기준으로 씀.
- 사이트 표시: `.entry-content.wp-block-post-content`. 무한 스크롤로 다음 기사가 이어 붙음(측정 도구가 처음엔 다음 기사까지 세어 고침). 영상 광고(JW Player). 쿠키 창 없음(한국 기준).
- 스크린샷(저장소 밖): techcrunch-all-1.png, techcrunch-all-2.png, techcrunch-all-3.png

## 필요한 규칙(제안)

1. "When you purchase through links in our articles, we may earn a small commission…" 빼기.
2. 끝 기자 소개(“… is a … reporter at TechCrunch”)·"You can contact or verify outreach from …" 빼기 — 메일 주소가 Cloudflare 보호로 "[email protected]" 이 되어 그대로 남음.
