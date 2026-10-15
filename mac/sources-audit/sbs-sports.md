# SBS 스포츠 (`sbs-sports`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: 없음 → 관찰한 유료 상태: 없음(전문 공개)
- 판정: **부분** — 방송 기사는 좋으나 영상 기사(글 거의 없음)에서 댓글 안내·사이트 꼬리 정보가 본문으로 나옴
- 기사 3건 · 완전성(우리/사이트 글자) 중앙값 106% · 사이트 문단 대조 중앙값 100%
- 점검: 2026-10-15, 앱 추출기(ReadSweep 와 같은 `ArticleExtractor.extract(allowScripts: true)`) + 헤드리스 Chromium(본문 상자 선택자는 tools/kr2/sitemeasure.js)

## 피드로 넘어오는 것

- RSS · 항목 29개
- 요약: 길이 중앙값 81자(최대 565) · HTML 든 요약 0/15 · 전문(content:encoded) 중앙값 1289자
- 사진: 15/15건에 있음 · 출처 content, enclosure, html-img, thumbnail
- 날짜 `Thu, 15 Oct 2026 10:47:00 +0900` 꼴 · 분야 15/15 · 기자 칸 15/15 · 링크 꼴 `https://news.sbs.co.kr/news/endPage.do?news_id=N<번호>&plink=RSSLINK&cooper=RSSREADER`

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| [기사 1](https://news.sbs.co.kr/news/endPage.do?news_id=N1008798340&plink=RSSLINK&cooper=RSSREADER) | fast | 746 / 697 (107%) · 문단 대조 100% | 없음 | 방송 대본 표시 3, 저작권 줄 1 | 우리 0장·설명 0 / 사이트 0장·설명 0 | - | fast 0.2초 |
| [기사 2](https://news.sbs.co.kr/news/endPage.do?news_id=N1008798839&plink=RSSLINK&cooper=RSSREADER) | fast | 775 / 738 (105%) · 문단 대조 100% | 없음 | 저작권 줄 1 | 우리 0장·설명 0 / 사이트 0장·설명 0 | - | 읽기 창이 숨기는 블록 1 · fast 0.3초 |
| [기사 3](https://news.sbs.co.kr/news/endPage.do?news_id=N1008798342&plink=RSSLINK&cooper=RSSREADER) | fast | 740 / ? | 없음 | 저작권 줄 1 | 우리 0장·설명 0 / 사이트 ?장·설명 ? | - | fast 0.2초 |

- '우리'는 읽기 창이 실제로 보여 줄 블록 — 추출 결과에서 읽기 창이 숨기는 것(BodyCleanup 의 '이름 기자 메일' 줄·짝 잃은 사진 설명, ImageKey.isJunk 그림)을 뺀 뒤 잼.
- 글자는 공백을 뺀 수. 우리 글자에는 사진 설명·끝 꼬리(저작권 등)가 들어가고, 사이트 글자는 본문 상자 안 보이는 글 전부.
- '문단 대조'는 사이트 본문 상자의 20자 넘는 줄 가운데 앞 25자가 우리 본문에 있는 비율(빠진 것의 척도). '섞인 것'은 우리 블록 가운데 종류 규칙에 걸린 수.

## 본 것

- 영상 기사: 앱 블록 = '첫 번째 댓글을 남겨주세요'·댓글 규정·'SBS뉴스 전체메뉴'·회사 정보 li 30여 줄. 이런 기사는 '본문 글이 거의 없는 기사(영상)' 안내가 맞음.
- 방송 리포트 기사의 '<앵커>'·'(영상취재 : …)' 줄은 사이트에도 그대로 있음 — 빼지 않아도 됨.

## 필요한 규칙(제안)

- 짧은 기사 안전장치: 뽑은 결과의 대부분이 li(목록)이거나 피드 제목·요약과 겹치는 낱말이 거의 없으면 실패(noText)로 보고 피드 요약을 보여 주기
- SBS 는 본문 상자를 `[itemprop=articleBody]` 로 지정 — 댓글·꼬리 제외
- 공통 끝 꼬리 정리(방송 대본 표시·저작권 줄) — 출처별이 아닌 공통 규칙
