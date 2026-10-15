# 한겨레 과학 (`hani-science`)

- 종류: feed · 기본켜짐: 아니오 · 지금 paywall 값: 없음 → 관찰한 유료 상태: 없음(전문 공개)
- 판정: **부분** — 본문 완전(긴 기사도 100%), 맨 앞에 오디오 플레이어 대체 글 한 줄
- 기사 3건 · 완전성(우리/사이트 글자) 중앙값 100% · 사이트 문단 대조 중앙값 100%
- 점검: 2026-10-15, 앱 추출기(ReadSweep 와 같은 `ArticleExtractor.extract(allowScripts: true)`) + 헤드리스 Chromium(본문 상자 선택자는 tools/kr2/sitemeasure.js)

## 피드로 넘어오는 것

- RSS · 항목 30개 · 주소가 308 로 옮겨짐
- 요약: 길이 중앙값 0자(최대 0) · HTML 든 요약 15/15 · 전문(content:encoded) 중앙값 0자
- 사진: 15/15건에 있음 · 출처 html-img
- 날짜 `` 꼴 · 분야 0/15 · 기자 칸 0/15 · 링크 꼴 `https://www.hani.co.kr/arti/science/technology/<번호>.html`

- 피드 주소가 308 로 끝 '/' 없는 주소로 옮겨짐 — URLSession 은 따라가 정상 동작, 주소를 `https://www.hani.co.kr/rss/science` 로 고쳐 두면 요청 1회 절약.
- 요약·전문 칸이 비고 사진(img)만 들어옴.

## 기사별

| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| [기사 1](https://www.hani.co.kr/arti/science/technology/1282479.html) | fast | 2567 / 2557 (100%) · 문단 대조 100% | 없음 | 오디오·플레이어 안내 1 | 우리 5장·설명 5 / 사이트 5장·설명 5 | - | 읽기 창이 숨기는 블록 1 · fast 0.3초 |
| [기사 2](https://www.hani.co.kr/arti/science/technology/1282282.html) | fast | 2184 / 2203 (99%) · 문단 대조 100% | 없음 | 오디오·플레이어 안내 1 | 우리 4장·설명 3 / 사이트 4장·설명 3 | - | 끼운 것 VIDEO · 읽기 창이 숨기는 블록 1 · fast 0.3초 |
| [기사 3](https://www.hani.co.kr/arti/science/science_general/1282077.html) | fast | 2165 / 2155 (100%) · 문단 대조 100% | 없음 | 오디오·플레이어 안내 1 | 우리 4장·설명 4 / 사이트 4장·설명 4 | - | 읽기 창이 숨기는 블록 1 · fast 0.3초 |

- '우리'는 읽기 창이 실제로 보여 줄 블록 — 추출 결과에서 읽기 창이 숨기는 것(BodyCleanup 의 '이름 기자 메일' 줄·짝 잃은 사진 설명, ImageKey.isJunk 그림)을 뺀 뒤 잼.
- 글자는 공백을 뺀 수. 우리 글자에는 사진 설명·끝 꼬리(저작권 등)가 들어가고, 사이트 글자는 본문 상자 안 보이는 글 전부.
- '문단 대조'는 사이트 본문 상자의 20자 넘는 줄 가운데 앞 25자가 우리 본문에 있는 비율(빠진 것의 척도). '섞인 것'은 우리 블록 가운데 종류 규칙에 걸린 수.

## 본 것

- 한겨레 공통: 첫 블록 '0:00Your browser does not support theaudio element.' — 기사 듣기 `<audio>` 안 대체 글이 본문으로 나옴.
- 사진 설명(figcaption)이 cap 으로 짝이 맞음.

## 필요한 규칙(제안)

- sources.json 피드 주소 끝 '/' 빼기(308 회피)
