# 조선일보 문화·라이프 (`chosun-culture`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: 없음 → 관찰한 유료 상태: 없음(전문 공개)
- 판정: **좋음** — 실린 본문 자료(Arc)로 3건 모두 0.4~0.6초, 소제목·인용·사진 설명까지 사이트와 같음
- 기사 3건 · 완전성(우리/사이트 글자) 중앙값 100% · 사이트 문단 대조 중앙값 100%
- 점검: 2026-10-15, 앱 추출기(ReadSweep 와 같은 `ArticleExtractor.extract(allowScripts: true)`) + 헤드리스 Chromium(본문 상자 선택자는 tools/kr2/sitemeasure.js)

## 피드로 넘어오는 것

- RSS · 항목 100개
- 요약: 길이 중앙값 0자(최대 225) · HTML 든 요약 0/15 · 전문(content:encoded) 중앙값 119자
- 사진: 14/15건에 있음 · 출처 content, html-img · 크기 표시 1019x1217, 1456x816, 1920x1080
- 날짜 `Wed, 14 Oct 2026 20:00:00 +0000` 꼴 · 분야 0/15 · 기자 칸 15/15 · 링크 꼴 `https://www.chosun.com/culture-life/culture_general/<번호>/10/15/V4WIBUTORFBBBJ6WQV5U7ZAJAY/`

- Arc 피드: 요약 칸 없음, content:encoded 에 앞부분(120~220자)과 사진(700×406 등 큰 크기).

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| [기사 1](https://www.chosun.com/culture-life/culture_general/2026/10/15/OT4SG76RIJDYPIVFENLGWLRXQE/) | embedded | 2669 / 2669 (100%) · 문단 대조 100% | 없음 | 없음 | 우리 9장·설명 9 / 사이트 9장·설명 9 | - | 소제목 우리 2/사이트 0 · 인용 2/2 · 유료·로그인 표시 · embedded 0.6초 |
| [기사 2](https://www.chosun.com/culture-life/culture_general/2026/10/15/N6QFUJYH25DGTCR5PHSLMO4M44/) | embedded | 900 / 900 (100%) · 문단 대조 100% | 없음 | 없음 | 우리 1장·설명 1 / 사이트 1장·설명 1 | - | 유료·로그인 표시 · embedded 0.6초 |
| [기사 3](https://www.chosun.com/culture-life/culture_general/2026/10/15/V4WIBUTORFBBBJ6WQV5U7ZAJAY/) | embedded | 790 / 790 (100%) · 문단 대조 100% | 없음 | 기자 이메일·바이라인 1 | 우리 1장·설명 1 / 사이트 1장·설명 1 | - | 유료·로그인 표시 · embedded 0.4초 |

- '우리'는 읽기 창이 실제로 보여 줄 블록 — 추출 결과에서 읽기 창이 숨기는 것(BodyCleanup 의 '이름 기자 메일' 줄·짝 잃은 사진 설명, ImageKey.isJunk 그림)을 뺀 뒤 잼.
- 글자는 공백을 뺀 수. 우리 글자에는 사진 설명·끝 꼬리(저작권 등)가 들어가고, 사이트 글자는 본문 상자 안 보이는 글 전부.
- '문단 대조'는 사이트 본문 상자의 20자 넘는 줄 가운데 앞 25자가 우리 본문에 있는 비율(빠진 것의 척도). '섞인 것'은 우리 블록 가운데 종류 규칙에 걸린 수.

## 본 것

- HTML 에 본문 글이 없어 빠른 길은 실패하고 `EmbeddedArticle`(Fusion.globalContent) 로 열림 — 느린 길 없이 완전.
- 긴 연재 기사의 머리 안내문('※문학은…')이 소제목(h)으로 나옴 — 사이트도 같은 위치에 굵게 표시하므로 문제 아님.

## 필요한 규칙(제안)

- 공통 끝 꼬리 정리(기자 이메일·바이라인) — 출처별이 아닌 공통 규칙
