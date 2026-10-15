# SBS 주요뉴스 (`sbs-top`)

- 종류: feed · 기본켜짐: 예 · 지금 paywall 값: 없음 → 관찰한 유료 상태: 없음(무료로 다 보임)
- **판정: 좋음** · 완전성 중앙값 100%(사이트 본문 문단 가운데 우리 글에 든 비율, 글자 기준 — 아래 표의 '덮기')
- 피드: 최근 15건 기준 — 요약 길이 중앙값 81자(최대 141) · HTML 든 요약 0건 · 전문(content:encoded 400자 넘음) 15건 · 사진 15건(content, enclosure, img-in-html, thumbnail) · 분야 15건 · 기자 15건 · 날짜 15건 · 링크 호스트 news.sbs.co.kr

본문 덮기 100%. 피드가 content:encoded 로 **전문**과 1280px 사진을 준다. 본문 영역(.text_area)엔 사진이 없고(사진·영상은 위쪽 따로) 앱도 피드 사진을 표지로. 맨 위 '▲위 사진은 기사 내용과 관련이 없습니다' 같은 사진 설명 줄은 사이트도 같은 자리.

| 기사 | 얻은 길 | 우리 / 사이트 글자 (%) · 덮기 | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |
|---|---|---|---|---|---|---|---|
| [1](https://news.sbs.co.kr/news/endPage.do?news_id=N1008798777&plink=RSSLINK&cooper=RSSREADER) | 빠른 길 0.2초 | 525 / 479 (110%) · 100% | - | 저작권 1 | 우리 0장·설명 0 / 사이트 0장·설명 0 | 해당 없음(국내) |  |
| [2](https://news.sbs.co.kr/news/endPage.do?news_id=N1008798194&plink=RSSLINK&cooper=RSSREADER) | 빠른 길 0.2초 | 399 / 333 (120%) · 100% | - | 구독·반응·공유 단추 1·저작권 1 | 우리 0장·설명 0 / 사이트 0장·설명 0 | 해당 없음(국내) | SNS 소개 기사 — 'SNS' 낱말은 본문(섞임 아님) |
| [3](https://news.sbs.co.kr/news/endPage.do?news_id=N1008798444&plink=RSSLINK&cooper=RSSREADER) | 빠른 길 0.3초 | 1169 / 1123 (104%) · 100% | - | 저작권 1 | 우리 0장·설명 0 / 사이트 0장·설명 0 | 해당 없음(국내) |  |

스크린샷(저장소 밖 srcaudit-shots/kr1): `sbs-top-1.png`, `sbs-top-2.png`, `sbs-top-3.png`

## 필요한 규칙(제안)

- R2: 'Copyright Ⓒ SBS' 줄 빼기
- (선택) 피드 content:encoded 가 전문이므로 미리 받기에서 페이지를 안 받아도 됨
