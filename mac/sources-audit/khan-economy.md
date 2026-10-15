# 경향신문 경제 (`khan-economy`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: 없음 → 관찰한 유료 상태: 없음(전문 공개)
- 판정: **좋음** — 본문 완전, 섞임 없음
- 기사 3건 · 완전성(우리/사이트 글자) 중앙값 93% · 사이트 문단 대조 중앙값 100%
- 점검: 2026-10-15, 앱 추출기(ReadSweep 와 같은 `ArticleExtractor.extract(allowScripts: true)`) + 헤드리스 Chromium(본문 상자 선택자는 tools/kr2/sitemeasure.js)

## 피드로 넘어오는 것

- RSS · 항목 50개
- 요약: 길이 중앙값 203자(최대 203) · HTML 든 요약 0/15 · 전문(content:encoded) 중앙값 0자
- 사진: 0/15건에 있음 · 출처 없음
- 날짜 `2026-10-15T11:08:00+09:00` 꼴 · 분야 15/15 · 기자 칸 15/15 · 링크 꼴 `https://www.khan.co.kr/article/<번호>/?utm_source=khan_rss&utm_medium=rss&utm_campaign=econo`

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| [기사 1](https://www.khan.co.kr/article/202610151108001/?utm_source=khan_rss&utm_medium=rss&utm_campaign=economy_news) | fast | 556 / 615 (90%) · 문단 대조 100% | 없음 | 없음 | 우리 1장·설명 0 / 사이트 1장·설명 1 | - | 목록 0/2 · fast 0.8초 |
| [기사 2](https://www.khan.co.kr/article/202610150738001/?utm_source=khan_rss&utm_medium=rss&utm_campaign=economy_news) | fast | 1015 / 1076 (94%) · 문단 대조 100% | 없음 | 없음 | 우리 1장·설명 0 / 사이트 1장·설명 1 · 설명이 문단으로 1 | - | 목록 0/2 · fast 0.6초 |
| [기사 3](https://www.khan.co.kr/article/202610151057001/?utm_source=khan_rss&utm_medium=rss&utm_campaign=economy_news) | fast | 647 / 698 (93%) · 문단 대조 100% | 없음 | 없음 | 우리 1장·설명 0 / 사이트 1장·설명 1 · 설명이 문단으로 1 | - | 목록 0/2 · fast 0.6초 |

- '우리'는 읽기 창이 실제로 보여 줄 블록 — 추출 결과에서 읽기 창이 숨기는 것(BodyCleanup 의 '이름 기자 메일' 줄·짝 잃은 사진 설명, ImageKey.isJunk 그림)을 뺀 뒤 잼.
- 글자는 공백을 뺀 수. 우리 글자에는 사진 설명·끝 꼬리(저작권 등)가 들어가고, 사이트 글자는 본문 상자 안 보이는 글 전부.
- '문단 대조'는 사이트 본문 상자의 20자 넘는 줄 가운데 앞 25자가 우리 본문에 있는 비율(빠진 것의 척도). '섞인 것'은 우리 블록 가운데 종류 규칙에 걸린 수.

## 본 것

- 경향 공통: 네이티브 광고는 빠지고 본문은 완전. 사진 설명이 p 로 나옴. 첫 블록이 부제(요약 한 줄)인 기사 있음 — p 로 나와 본문 첫 문단처럼 보임.

## 필요한 규칙(제안)

- 사진 바로 뒤 '… 제공/연합뉴스/뉴스1' 로 끝나는 짧은 p 는 사진 설명(cap)으로 바꾸기(경향 공통)
