# BBC Sport (`bbc-sport`)

- 종류: feed · 기본켜짐: 예 · 지금 paywall 값: 없음
- 관찰한 유료 상태: 없음(무료)
- **판정: 부분** — 글은 98% 맞으나 사진이 다 빠짐. 영상 페이지 둘은 소개 글만(사이트도 그 정도) — 한국에서는 영상이 "이 지역에서 볼 수 없음".
- 완전성 중앙값(사이트 본문 글 중 앱 본문에 있는 비율): 100% · 점검일 2026-10-15 · 기사 3건

## 피드로 넘어오는 것

- RSS. 제목 + 요약 90~225자(맨 글자, HTML 없음). 본문 없음(전문 아님).
- 사진: media:thumbnail 240px 하나 → 앱은 og:image(1200px)로 바꿔 씀(READSWEEP 고침 그대로 동작).
- 날짜 있음 · 분야(category)·기자 없음 · 링크에 `?at_medium=RSS&at_campaign=rss` 추적 꼬리.
- 이날 BBC Sport 피드 맨 위에 news/articles(정치 기사)가 섞여 들어옴 — 분야가 다른 기사가 Sport 로 표시됨.

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| `bbc.co.uk/news/articles/c83vq9vpwwr1o ?at_medium&at_campaign` — 최신 | 빠른 길 0.2초 | 5730 / 5837 (98%) · 사이트 글의 100% 있음 | (사이트 홍보·안내 1 — 빠져도 됨) | 없음 | 사이트 2 / 우리 0 · 표지 feed→og 1200×675 | - | 사진 2장 빠짐, 끝 뉴스레터 안내는 빠져도 됨 |
| `bbc.co.uk/sport/football/videos/ck0j07zegp7xo ?at_medium&at_campaign` — 피드 글 가장 김 | 빠른 길 0.3초 | 307 / 420 (73%) · 사이트 글의 100% 있음 | (사이트 홍보·안내 1 — 빠져도 됨) | 없음 | 사이트 0 / 우리 0 · 표지 feed→og 1200×675 | - | 영상 소개 3문단(사이트도 비슷) — 영상은 지역 제한 |
| `bbc.co.uk/sport/football/videos/cw2409qg6pe0o ?at_medium&at_campaign` — 짧은 글·속보 후보 | 빠른 길 0.2초 | 318 / 422 (75%) · 사이트 글의 100% 있음 | (사이트 홍보·안내 1 — 빠져도 됨) | 없음 | 사이트 0 / 우리 0 · 표지 feed→og 1200×675 | - | 위와 같음 |

- 얻은 길·초·표지는 실제 앱(점검 모드)으로 잰 값, 블록 비교는 같은 추출 스크립트를 헤드리스 WebKit 으로 돌린 재현 값(_INTL1.md 의 '재는 법'). ᴸ = 사이트가 유료벽·차단으로 본문을 감춰 기사 머리의 schema.org articleBody 길이를 기준으로 씀.
- 사이트 표시: 본문은 `main article` 안에 `[data-component=text-block]`·`image-block`·`subheadline-block`·`list-block` 이 형제로 늘어선 꼴, 끝에 관련 기사 카드. 유료벽·쿠키 창 없음(한국에서 연 헤드리스 기준). 영상 페이지(`/videos/`)는 영상 + 짧은 소개 1~6문단, 일부 영상은 "이 지역에서 볼 수 없음".
- 스크린샷(저장소 밖): bbc-sport-1.png, bbc-sport-2.png, bbc-sport-3.png

## 필요한 규칙(제안)

1. BBC 전용 본문 모으기: `main article` 의 `[data-component$="-block"]` 를 문서 순서대로(text-block → p, subheadline → h, image-block → img+cap, list-block → li). Readability 가 뒤쪽 덩어리만 고르는 일을 막는다.
2. `/videos/` 주소에서 BBC 바닥글(Accessibility Help·Contact the BBC·Copyright ©…)만 잡히면 "글이 거의 없는 기사"로 실패 처리. 바닥글 문구 거르기는 일반 규칙으로도.
3. image-block 사진이 빠지는데 사진 설명만 남으면(짝 잃은 설명) 설명도 빼기.
4. 영상 페이지에서 "This content is not available in your location" 이 보이면 읽기 창에 "영상은 지역 제한" 안내.
