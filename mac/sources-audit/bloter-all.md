# 블로터 (`bloter-all`)

- 종류: feed · 기본켜짐: 예 · 지금 paywall 값: 없음 → 관찰한 유료 상태: 없음(전문 공개)
- 판정: **좋음** — 3건 모두 사이트 본문과 글자 수가 같고 사진·설명 짝도 맞음
- 기사 3건 · 완전성(우리/사이트 글자) 중앙값 100% · 사이트 문단 대조 중앙값 100%
- 점검: 2026-10-15, 앱 추출기(ReadSweep 와 같은 `ArticleExtractor.extract(allowScripts: true)`) + 헤드리스 Chromium(본문 상자 선택자는 tools/kr2/sitemeasure.js)

## 피드로 넘어오는 것

- RSS · 항목 50개
- 요약: 길이 중앙값 300자(최대 300) · HTML 든 요약 0/15 · 전문(content:encoded) 중앙값 0자
- 사진: 0/15건에 있음 · 출처 없음
- 날짜 `2026-10-15 11:10:52` 꼴 · 분야 0/15 · 기자 칸 15/15 · 링크 꼴 `https://www.bloter.net/news/articleView.html?idxno=<번호>`

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| [기사 1](https://www.bloter.net/news/articleView.html?idxno=675729) | fast | 1615 / 1615 (100%) · 문단 대조 100% | 없음 | 없음 | 우리 3장·설명 3 / 사이트 3장·설명 3 | - | fast 0.3초 |
| [기사 2](https://www.bloter.net/news/articleView.html?idxno=675738) | fast | 2020 / 2020 (100%) · 문단 대조 100% | 없음 | 없음 | 우리 1장·설명 1 / 사이트 1장·설명 1 | - | fast 0.4초 |
| [기사 3](https://www.bloter.net/news/articleView.html?idxno=675735) | fast | 1559 / 1559 (100%) · 문단 대조 100% | 없음 | 없음 | 우리 2장·설명 2 / 사이트 2장·설명 2 | - | fast 0.2초 |

- '우리'는 읽기 창이 실제로 보여 줄 블록 — 추출 결과에서 읽기 창이 숨기는 것(BodyCleanup 의 '이름 기자 메일' 줄·짝 잃은 사진 설명, ImageKey.isJunk 그림)을 뺀 뒤 잼.
- 글자는 공백을 뺀 수. 우리 글자에는 사진 설명·끝 꼬리(저작권 등)가 들어가고, 사이트 글자는 본문 상자 안 보이는 글 전부.
- '문단 대조'는 사이트 본문 상자의 20자 넘는 줄 가운데 앞 25자가 우리 본문에 있는 비율(빠진 것의 척도). '섞인 것'은 우리 블록 가운데 종류 규칙에 걸린 수.

## 본 것

- ndsoft 계열(`#article-view-content-div`) — Readability 가 정확히 본문 상자만 잡음. 사진 설명이 figure 안 figcaption 이라 cap 블록으로 짝이 맞음.

## 필요한 규칙(제안)

- 없음(지금 그대로 좋음)
