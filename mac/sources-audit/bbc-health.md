# BBC Health (`bbc-health`)

- 종류: feed · 기본켜짐: 예 · 지금 paywall 값: 없음
- 관찰한 유료 상태: 없음(무료)
- **판정: 나쁨** — 사진이 있는 기사에서 Readability 가 뒤쪽 덩어리만 골라 앞 7문단·사진 4장이 빠짐. 영상 페이지는 BBC 바닥글(링크 목록·Copyright)이 본문으로 나옴.
- 완전성 중앙값(사이트 본문 글 중 앱 본문에 있는 비율): 73% · 점검일 2026-10-15 · 기사 3건

## 피드로 넘어오는 것

- RSS. 제목 + 요약 90~225자(맨 글자, HTML 없음). 본문 없음(전문 아님).
- 사진: media:thumbnail 240px 하나 → 앱은 og:image(1200px)로 바꿔 씀(READSWEEP 고침 그대로 동작).
- 날짜 있음 · 분야(category)·기자 없음 · 링크에 `?at_medium=RSS&at_campaign=rss` 추적 꼬리.

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| `bbc.co.uk/news/articles/cwr7yz5x7pj0o ?at_medium&at_campaign` — 최신 | 빠른 길 0.3초 | 2654 / 3663 (72%) · 사이트 글의 73% 있음 | 앞 문단 6 · 중간 문단 1 | 없음 | 사이트 4 / 우리 0 · 표지 feed→og 1200×675 | - | 앞 7문단·사진 4장(설명 4) 빠짐 — 첫 사진 뒤부터 시작 |
| `bbc.co.uk/news/articles/cm74pn052j2vo ?at_medium&at_campaign` — 피드 글 가장 김 | 빠른 길 0.2초 | 5522 / 5481 (101%) · 사이트 글의 100% 있음 | 없음 | 기자·지역 줄(“이름 and 이름BBC Scotland” 꼴) | 사이트 1 / 우리 1 · 설명 3 · 짝 잃은 설명 2 · 표지 feed→og 1200×675 | - | 본문 완전, 그러나 사진 1장에 설명 3개(짝 잃은 설명 2) · 기자·지역 줄이 첫 문단으로 |
| `bbc.co.uk/news/videos/cry4xkyy17xvo ?at_medium&at_campaign` — 짧은 글·속보 후보 | 빠른 길 0.2초 | 266 / 0 (영상 페이지) | - | 사이트 바닥글 10줄이 본문 전부 | 사이트 0 / 우리 0 · 표지 feed→og 1200×675 | - | 앱은 성공으로 보고 바닥글을 본문으로 보여 줌 — 실패(영상 기사)여야 함 |

- 얻은 길·초·표지는 실제 앱(점검 모드)으로 잰 값, 블록 비교는 같은 추출 스크립트를 헤드리스 WebKit 으로 돌린 재현 값(_INTL1.md 의 '재는 법'). ᴸ = 사이트가 유료벽·차단으로 본문을 감춰 기사 머리의 schema.org articleBody 길이를 기준으로 씀.
- 사이트 표시: 본문은 `main article` 안에 `[data-component=text-block]`·`image-block`·`subheadline-block`·`list-block` 이 형제로 늘어선 꼴, 끝에 관련 기사 카드. 유료벽·쿠키 창 없음(한국에서 연 헤드리스 기준). 영상 페이지(`/videos/`)는 영상 + 짧은 소개 1~6문단, 일부 영상은 "이 지역에서 볼 수 없음".
- 스크린샷(저장소 밖): bbc-health-1.png, bbc-health-2.png, bbc-health-3.png

## 필요한 규칙(제안)

1. BBC 전용 본문 모으기: `main article` 의 `[data-component$="-block"]` 를 문서 순서대로(text-block → p, subheadline → h, image-block → img+cap, list-block → li). Readability 가 뒤쪽 덩어리만 고르는 일을 막는다.
2. `/videos/` 주소에서 BBC 바닥글(Accessibility Help·Contact the BBC·Copyright ©…)만 잡히면 "글이 거의 없는 기사"로 실패 처리. 바닥글 문구 거르기는 일반 규칙으로도.
3. image-block 사진이 빠지는데 사진 설명만 남으면(짝 잃은 설명) 설명도 빼기.
