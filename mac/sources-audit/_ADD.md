# 출처 추가(source-add) — 빠진 공신력 있는 매체 찾기

> 2026-10-15 · 작업자 SrcAdd · 브랜치 `wt/source-add`. 기존 120곳은 고치지 않고 **28곳을 더함 → 148곳(국내 83 · 해외 65)**. 새 출처는 모두 `defaultOn: false`.

## 요약

- 후보 41개(같은 매체의 다른 피드 포함)를 앱과 같은 길로 점검했다: 피드 받기(`FeedService.items`, 사이트맵이면 `fillTitle`) → 기사 3건 본문(`ArticleExtractor.extract(allowScripts: true)` + 읽기 창의 숨김 규칙) → 헤드리스 Chromium 으로 같은 기사 페이지의 본문 영역 글자 수(화면 뺏지 않음). 출처마다 결과는 `<id>.md`.
- **넣음 28**: 해외 15(Reuters · Axios · The Atlantic · Le Monde 영어판 · France 24 · PBS NewsHour · ProPublica · Scientific American · IEEE Spectrum · Guardian Technology + 하드 유료 5: FT · The Economist · Bloomberg Markets · Bloomberg Technology · Nikkei Asia), 국내 13(중앙일보 · 한국일보 · 문화일보 · 국민일보 · 서울신문 · JTBC · 뉴시스 정치 · 세계일보 정치 · 이데일리 경제 · 프레시안 · 오마이뉴스 주요기사 · 한겨레 정치 · 한겨레 경제).
- **뺌 13**: 앱이 피드를 못 읽음(Nature · Rest of World), 본문 차단(Science News), 본문이 틀림(뉴스1 — 바닥글, SCMP — 앞 4문단만), 받기 부담·날짜 없음(KBS · YTN 사이트맵), 공식 자료가 첨부 위주(한국은행), 분량 때문에 분야 피드로 바꿈(뉴시스 속보 · 세계일보 전체 · 이데일리 전체 · 오마이뉴스 전체 · 머니투데이).
- **피드가 아예 없거나 끊긴 곳**(후보 표에 없음): AP(사이트맵·피드 모두 403), Washington Post(공식 피드 502 — 서비스 중단으로 보임), AFP(공개 피드 없음 → France 24 로 대신), 정책브리핑(RSS 2026-07-01 종료 공지), 통계청(RSS 없음), 시사IN(피드가 2024-06 에 멈춤), 뉴스타파(403), JTBC 옛 피드(2024 멈춤 — 새 주소로 넣음).
- 정파 균형(국내 새 출처): 보수 쪽 중앙·문화·세계 / 중도 한국·국민·서울·JTBC·뉴시스 / 진보 쪽 한겨레(정치·경제)·프레시안·오마이뉴스. 기존(조선·동아·한경·매경 대 경향·한겨레·노컷·MBC)과 합쳐도 한쪽으로 쏠리지 않게 맞춤.
- 사이트맵 출처 4곳(Reuters · 중앙 · 한국 · 문화)은 공식 RSS 가 없어 구글 뉴스용 공개 사이트맵을 쓴다. 기존 Anthropic 과 같은 방식(앱에 든 거르기 정규식만 씀 — 보안 점검 규칙). 새 글마다 기사 페이지를 한 번 받아 제목·요약·사진을 채우므로, 하루 200~300건인 이 네 곳은 켜면 받기가 늘어난다(5분 간격 기준 사이트맵 150~370KB, gzip 전송).

## 하드 유료(넣을지 결정필요)

FT · The Economist · Bloomberg 2곳 · Nikkei Asia 는 넣되 `paywall: "hard"` 로 표시했다. 앱이 얻는 것은 구독 권유 페이지(FT), 첫 문단·목차(Economist), 요점 목록(Bloomberg), 앞 2~3문단(Nikkei)이다. 피드의 제목·요약은 좋아서 **'무슨 일이 났는지'를 알리는 출처로는 쓸모가 있고**, 읽기 창은 유료 표시(hard)와 원문 열기를 안내한다. Bloomberg·Nikkei 는 앱의 `Paywall.looksBlocked` 가 막힘을 알아보지 못해 sources.json 의 hard 값으로만 표시된다.
- 선택지: ① 그대로 넣음(기본 꺼짐, 유료 표시) ② 빼기 ③ Economist·FT 만 남기기.
- 내 추천: ① — 기존 WSJ Markets(hard)와 같은 처리라 일관적이고, 사용자가 켜지 않으면 아무 영향이 없다.

## 기본 켜짐 추천(사용자 결정)

새 출처는 모두 꺼 두었다. 켤 만한 곳(분야별 국내·해외 균형, 본문 '좋음', 무료, 하루 글 수 적당):
- 국제: **Reuters**(통신사 1차 보도, 해외 국제의 BBC·Guardian 과 겹치지 않는 속도) — 다만 하루 200여 건·사이트맵이라 기본 켜짐은 부담이 있어 '추천' 정도
- 주요 뉴스: **중앙일보**(국내 3대 종합지 중 유일하게 빠져 있었음 — 지금 주요 뉴스 기본은 SBS·BBC)
- 과학·IT: **IEEE Spectrum**(하루 1~2건, 본문 좋음)
- 사회: **ProPublica**(하루 2건 남짓, 긴 탐사보도를 온전히 얻음 — 사회 분야 첫 해외 출처)
- 켜지 말 것: 하드 유료 5곳, 사이트맵 출처를 둘 이상 동시에(받기 부담).

## 후보 전체 표

판정: 좋음(본문 90% 이상·섞임 없음) / 부분(본문은 있으나 섞임·일부 빠짐) / 나쁨(본문이 틀리거나 유료로 막힘) / 실패·차단(받지 못함). 하루 글 수는 2026-10-15 오전 한 번 받은 피드의 시간 폭으로 어림했다(낮 시간대엔 더 많을 수 있음).

| 결과 | id | 이름 | 지역·분야 | 종류·주소 | 유료(paywall) | 하루 글(어림) | 판정 | 이유 |
|---|---|---|---|---|---|---|---|---|
| **넣음** | [`atlantic`](atlantic.md) | The Atlantic | intl·문화 | feed `https://www.theatlantic.com/feed/all/` | metered | ~20 | 좋음 | 본문 3.4~7.8천 자 모두 얻음. 사이트 측정은 선택자가 본문 일부만 잡아 % 가 100 을 넘음(앱이 더 많음 = 빠진 것 없음) |
| **넣음** | [`ft`](ft.md) | Financial Times | intl·경제 | feed `https://www.ft.com/rss/home` | hard | ~10 | 나쁨(유료) | 공신력 최상위 경제지지만 하드 유료. paywall=hard 로 넣어 목록에서 유료 표시만 보이게(기본 꺼짐). 넣을지는 결정필요 |
| **넣음** | [`bloomberg-markets`](bloomberg-markets.md) | Bloomberg Markets | intl·경제 | feed `https://feeds.bloomberg.com/markets/news.rss` | hard | ~55 | 나쁨(유료) | 하드 유료·봇 차단. 영상·뉴스레터 글이 섞임. paywall=hard 로 넣음, 넣을지는 결정필요 |
| **넣음** | [`nikkei-asia`](nikkei-asia.md) | Nikkei Asia | intl·경제 | feed `https://asia.nikkei.com/rss/feed/nar` | hard | ~50 | 나쁨(유료) | 아시아 경제 1차 보도. 하드 유료로 넣고 넣을지는 결정필요 |
| **넣음** | [`axios`](axios.md) | Axios | intl·정치 | feed `https://api.axios.com/feed/` | 없음 | ~13 | 좋음 | 미국 정치·정책 단신. 본문 108~114%(앱이 요점 목록 머리까지 담음) |
| **넣음** | [`sciam`](sciam.md) | Scientific American | intl·과학 | feed `https://www.scientificamerican.com/platform/syndication/rss/` | metered | ~6 | 부분 | 본문은 다 얻지만 꼬리에 '구독으로 과학 저널리즘 지원' 상자(소제목 2·문단 3)가 섞임 |
| **넣음** | [`propublica`](propublica.md) | ProPublica | intl·사회 | feed `https://www.propublica.org/feeds/propublica/main` | 없음 | ~2 | 좋음 | 탐사보도 비영리(퓰리처 다수). 긴 기사(4~28천 자)를 100~117% 로 얻음. 하루 2건 남짓 |
| **넣음** | [`bloomberg-tech`](bloomberg-tech.md) | Bloomberg Technology | intl·IT | feed `https://feeds.bloomberg.com/technology/news.rss` | hard | ~30 | 나쁨(유료) | bloomberg-markets 와 같음. 넣을지는 결정필요 |
| **넣음** | [`ieee-spectrum`](ieee-spectrum.md) | IEEE Spectrum | intl·IT | feed `https://spectrum.ieee.org/feeds/feed.rss` | 없음 | ~1 | 좋음 | IEEE 기술 전문지. 본문 83~97%(빠진 것은 사진 설명 일부) |
| **넣음** | [`guardian-tech`](guardian-tech.md) | Guardian Technology | intl·IT | feed `https://www.theguardian.com/technology/rss` | 없음 | ~28 | 좋음 | 기존 Guardian 출처의 빠진 분야(IT). 본문 99~106% |
| **넣음** | [`pbs-newshour`](pbs-newshour.md) | PBS NewsHour | intl·주요 | feed `https://www.pbs.org/newshour/feeds/rss/headlines` | 없음 | ~66 | 좋음 | 미국 공영방송 뉴스. 본문 105~109% |
| **넣음** | [`reuters`](reuters.md) | Reuters | intl·국제 | sitemap `https://www.reuters.com/arc/outboundfeeds/news-sitemap/?outputType=xml` | 없음 | ~235 | 좋음 | 세계 3대 통신사. 공식 RSS 가 없어 공개 뉴스 사이트맵(구글 뉴스용, 최근 이틀·lastmod 있음)을 씀. 앱 느린 길로 2.8~5.4천 자 |
| **넣음** | [`economist`](economist.md) | The Economist | intl·국제 | feed `https://www.economist.com/latest/rss.xml` | hard | ~15 | 나쁨(유료) | 하드 유료. 피드 제목·한 줄 요약은 좋음. paywall=hard 로 넣음, 넣을지는 결정필요 |
| **넣음** | [`lemonde-en`](lemonde-en.md) | Le Monde (English) | intl·국제 | feed `https://www.lemonde.fr/en/rss/une.xml` | metered | ~17 | 좋음 | 프랑스 대표 일간지 영어판. 앱 1.4~4.7천 자. 헤드리스 Chromium 은 봇 확인 창이 떠서 사이트 글자 수는 못 잼 |
| **넣음** | [`france24`](france24.md) | France 24 | intl·국제 | feed `https://www.france24.com/en/rss` | 없음 | ~48 | 좋음 | 프랑스 공영 국제방송(AFP 기사 다수 실음). 본문 100~109% |
| **넣음** | [`hani-economy`](hani-economy.md) | 한겨레 경제 | kr·경제 | feed `https://www.hani.co.kr/rss/economy/` | 없음 | ~30 | 좋음 | 기존 한겨레 출처의 빠진 분야(경제). 본문 104~107% |
| **넣음** | [`edaily-economy`](edaily-economy.md) | 이데일리 경제 | kr·경제 | feed `http://rss.edaily.co.kr/economy_news.xml` | 없음 | ~67 | 부분 | 경제지 경제 분야(전체 피드 대신). 기사 문단은 다 얻지만 앞에 '등록 시각'·'가 가'(글자 크기 단추) 목록 2줄, 끝에 '주요뉴스' 한 줄이 섞임. 사이트 측정은 선택자가 빗나가 앱 블록을 직접 확인함 |
| **넣음** | [`pressian`](pressian.md) | 프레시안 | kr·정치 | feed `https://www.pressian.com/api/v3/site/rss/news` | 없음 | 수백 | 좋음 | 진보 성향 인터넷 신문(정파 균형). 본문 103~109% |
| **넣음** | [`hani-politics`](hani-politics.md) | 한겨레 정치 | kr·정치 | feed `https://www.hani.co.kr/rss/politics/` | 없음 | ~30 | 좋음 | 기존 한겨레 출처의 빠진 분야(정치). 본문 113~123%(앱이 사진 설명까지 셈) |
| **넣음** | [`newsis-politics`](newsis-politics.md) | 뉴시스 정치 | kr·정치 | feed `https://www.newsis.com/RSS/politics.xml` | 없음 | ~125 | 좋음 | 민영 통신사 정치 분야(속보 피드 대신). 본문 1.5~1.8천 자, 꼬리 '공감언론 뉴시스' 기자 줄. 사이트 측정은 선택자가 빗나가 앱 블록을 직접 확인함(기사 문단만) |
| **넣음** | [`segye-politics`](segye-politics.md) | 세계일보 정치 | kr·정치 | feed `https://www.segye.com/Articles/RSSList/segye_politic.xml` | 없음 | ~40 | 좋음 | 중도보수 종합지 정치 분야(전체 피드 대신). 본문 0.8~1.3천 자, 사이트와 100% 안팎. 꼬리 저작권 줄 |
| **넣음** | [`jtbc-news`](jtbc-news.md) | JTBC 뉴스 | kr·주요 | feed `https://news-ex.jtbc.co.kr/v1/get/rss/newsflesh` | 없음 | ~11 | 좋음 | 종편 보도 1위권. 새 피드(news-ex)는 살아 있음(예전 fs.jtbc 피드는 2024년에 멈춤). 느린 길(1.7~15초)로 본문 100% |
| **넣음** | [`joongang`](joongang.md) | 중앙일보 | kr·주요 | sitemap `https://www.joongang.co.kr/sitemap/latest-articles` | 없음 | ~300 | 좋음 | 보수 종합지 3대지 중 빠져 있던 곳. RSS 는 2024년 종료, 최근 기사 사이트맵(lastmod 있음, 150KB)을 씀. 본문 93~100% |
| **넣음** | [`hankook`](hankook.md) | 한국일보 | kr·주요 | sitemap `https://www.hankookilbo.com/sitemap/latest-articles` | 없음 | ~230 | 좋음 | 중도 종합지. RSS 없음, 최근 기사 사이트맵을 씀. 본문 100% |
| **넣음** | [`munhwa`](munhwa.md) | 문화일보 | kr·주요 | sitemap `https://www.munhwa.com/sitemap/latest-articles` | 없음 | ~300 | 부분 | 보수 석간 종합지. RSS 없음, 사이트맵을 씀. 앱 64~75% — 앱 블록을 보면 기사 문단은 다 있고, 사이트 쪽 측정에 사진 설명·기자 줄이 더 들어간 차이로 보임 |
| **넣음** | [`kmib`](kmib.md) | 국민일보 | kr·주요 | feed `https://www.kmib.co.kr/rss/data/kmibRssAll.xml` | 없음 | ~30 | 좋음 | 중도 종합지. 짧은 기사(0.1~0.6천 자) 그대로. 꼬리의 기자 줄·저작권 줄은 BodyCleanup 이 숨김 |
| **넣음** | [`seoul`](seoul.md) | 서울신문 | kr·주요 | feed `https://www.seoul.co.kr/xml/rss/google_top.xml` | 없음 | ~26 | 부분 | 중도 종합지(가장 오래된 일간지). 본문은 다 얻지만 꼬리에 'AI 퀴즈'·'기사 반응' 상자, 앞에 '이미지 확대' 글자가 섞임 |
| **넣음** | [`ohmynews-top`](ohmynews-top.md) | 오마이뉴스 주요기사 | kr·주요 | feed `http://rss.ohmynews.com/rss/top.xml` | 없음 | ~25 | 좋음 | 진보 성향 인터넷 신문 주요기사(전체 피드 대신, 하루 20여 건). 본문 1.4~4.7천 자. 맨 앞에 '모든 시민은 기자다' 안내 문단이 섞이는 기사가 있음(시민기자 글) |
| 뺌 | [`nature`](nature.md) | Nature | intl·과학 | feed `https://www.nature.com/nature.rss` | metered | ~38 | 실패 | 앱 받기가 형식 오류(badFormat) — 쿠키가 필요한 로그인 서버 리다이렉트(303→302→302)를 거쳐 앱에는 피드가 오지 않음. 이전(일반 뉴스 전환)에도 같은 사유로 뺌. 피드에 논문 초록이 뉴스와 섞이는 문제도 있음 |
| 뺌 | [`science-news`](science-news.md) | Science (AAAS) News | intl·과학 | feed `https://www.science.org/rss/news_current.xml` | 없음 | ~7 | 차단 | 빠른 길·느린 길 모두 403(봇 확인 페이지, 108자). 피드는 받아지지만 본문을 못 얻음 |
| 뺌 | [`restofworld`](restofworld.md) | Rest of World | intl·IT | feed `https://restofworld.org/feed/latest` | 없음 | ~1 | 실패 | 피드 XML 이 깨짐(사진 주소의 & 를 이스케이프하지 않음) — 앱 파서가 12건 중 1건만 읽음. 본문 추출은 좋음(6천 자) |
| 뺌 | [`scmp`](scmp.md) | South China Morning Post | intl·국제 | feed `https://www.scmp.com/rss/91/feed` | metered | ~65 | 나쁨 | 나머지 본문을 스크립트로 붙이는 페이지라 빠른 길이 일부만 얻고도 '글이 많은 페이지'로 보고 멈춤. 느린 길 강제 규칙이 생기면 다시 보기 |
| 뺌 | [`edaily`](edaily.md) | 이데일리 | kr·경제 | feed `http://rss.edaily.co.kr/edaily_news.xml` | 없음 | 수천 | 좋음(본문) · 분야 피드로 바꿈 | 전체 피드는 하루 수천 건 꼴이라 경제 분야 피드(edaily-economy)로 넣음 |
| 뺌 | [`mt`](mt.md) | 머니투데이 | kr·경제 | feed `https://rss.mt.co.kr/mt_news.xml` | 없음 | ~1600 | 좋음(본문) · 보류(분량) | 본문 92~114% 로 좋지만 살아 있는 피드는 전체(하루 1천6백 건 꼴)뿐이고 분야 피드는 2025-09 에 멈춤. 경제 분야에 국내 출처가 이미 많음 |
| 뺌 | [`bok-stats`](bok-stats.md) | 한국은행 보도자료(통계) | kr·경제 | feed `https://www.bok.or.kr/portal/bbs/B0000501/news.rss?menuNo=200690` | 없음 | 주 몇 건 | 나쁨 | 피드는 좋지만(통계 보도자료, 요약에 핵심 수치) 기사 페이지 본문은 요약 몇 줄과 첨부(PDF·HWP)라 3건 중 2건 추출 실패. 공식 발표 출처 가치는 있음 — 읽기 창이 피드 요약을 본문 대신 보여 주는 길이 생기면 넣기 |
| 뺌 | [`ohmynews`](ohmynews.md) | 오마이뉴스 | kr·정치 | feed `http://rss.ohmynews.com/rss/ohmynews.xml` | 없음 | ~500 | 좋음(본문) · 분야 피드로 바꿈 | 전체 피드는 하루 5백 건 꼴(시민기자 글 포함)이라 주요기사 피드(ohmynews-top)로 넣음 |
| 뺌 | [`kbs-news`](kbs-news.md) | KBS 뉴스 | kr·주요 | sitemap `https://news.kbs.co.kr/sitemap/recentNewsList.xml` | 없음 | ~1000 | 좋음(본문) · 보류(받기 부담) | 공영방송 1위지만 RSS 가 없고, 사이트맵이 1.5MB·3천5백 건(하루 약 1천 건)이라 5분마다 받기와 새 글마다 페이지 받기(fillTitle) 부담이 큼. 본문 추출은 좋음(0.5~0.6천 자 방송 기사) |
| 뺌 | [`ytn`](ytn.md) | YTN | kr·주요 | sitemap `https://www.ytn.co.kr/sitemap/sitemap0.xml` | 없음 | ~1000(날짜 없음) | 좋음(본문) · 보류(받기 부담) | RSS 없음. 사이트맵 1천 건·날짜(lastmod) 없음·380KB 라 새 글 판단을 맨 위 글 바뀜에만 기대야 함. 본문 추출은 좋음 |
| 뺌 | [`segye`](segye.md) | 세계일보 | kr·주요 | feed `https://www.segye.com/Articles/RSSList/segye_recent.xml` | 없음 | ~600 | 좋음(본문) · 분야 피드로 바꿈 | 전체 최신 피드는 하루 6백 건 꼴이라 정치 분야 피드(segye-politics)로 넣음 |
| 뺌 | [`news1`](news1.md) | 뉴스1 | kr·주요 | feed `https://www.news1.kr/api/feeds/google/` | 없음 | ~60 | 나쁨 | 앱이 기사 대신 사이트 바닥글(회사 정보)을 본문으로 얻음(17~32%). 피드는 좋음(구글 뉴스용 RSS) |
| 뺌 | [`newsis`](newsis.md) | 뉴시스 속보 | kr·주요 | feed `https://www.newsis.com/RSS/sokbo.xml` | 없음 | 수천 | 좋음(본문) · 분야 피드로 바꿈 | 속보 피드는 하루 수천 건 꼴이라 정치 분야 피드(newsis-politics)로 넣음 |

## 점검 방법과 한계

- 도구: `tools/add/` — `probe_feeds.py`(후보 피드 생존·최근 글), `rate.py`(하루 글 수 어림), `AddProbe.swift` + `run-probe.sh`(앱 코드 그대로 피드·본문, 시험 폴더에 잠깐 복사해 `swift test --filter AddProbe`), `site.mjs`(헤드리스 Chromium 본문 영역 측정, srcaudit-intl1 과 같은 측정 함수 + 선택자가 빗나가면 문단이 가장 많이 모인 상자로 다시 잼), `merge.py`(sources.json 끝에 덧붙이기, 기존 항목 그대로), `gen_md.py`·`gen_add.py`(이 문서들).
- 요청 사이 1~1.5초, 출처마다 기사 3건. 본문·기자 이름·사진은 저장소에 남기지 않음(글자 수·꼴만).
- 사이트 글자 수는 선택자 기준이라 국내 일부(이데일리·뉴시스·오마이뉴스·KBS·YTN·서울)는 측정이 빗나갔다 — 그런 곳은 앱 블록을 직접 보고 판정했고 md 에 '측정 빗나감'으로 적었다. Reuters·Bloomberg·Economist 는 헤드리스 Chromium 이 401/403(봇 차단), Le Monde 는 봇 확인 창이라 사이트 쪽을 못 쟀다.
- 피드 이용: 모두 매체가 공개한 RSS·사이트맵을 개인용 리더 수준(5분 간격 받기, 기사 링크로 원문 열기)으로 쓴다. 본문을 다시 배포하지 않는다. 뉴스1 의 `api/feeds/google` 처럼 '구글 뉴스용'으로 이름 붙은 피드는 뺐다(본문 문제와 별개로 용도가 분명하지 않음). 사이트맵 4곳은 robots.txt 가 공개한 주소다.

## 다른 담당에게 넘길 것(이 작업에서 고치지 않음)

1. **mac 시험** `LiveSourceDatesTests`(DROPCAP_LIVE_TESTS=1 일 때만 도는 실제 네트워크 시험)의 '날짜 없는 피드' 목록에 `hani-politics`·`hani-economy` 를 더해야 한다 — 한겨레 피드는 글 날짜가 없다. 평소 `swift test` 에는 영향 없음.
2. **앱 코드(FeedParser.parseSitemap)**: `lastmod` 만 읽는다. 한국일보·문화일보 사이트맵은 `news:publication_date` 만 있어 날짜가 비고, 처음 본 시각으로 채워진다. `news:publication_date` 도 읽으면 정확해진다(맥·윈도우·리눅스 같이).
3. **앱 코드(피드 파서)**: Rest of World 피드처럼 속성 안 `&` 가 이스케이프되지 않은 피드를 너그럽게 읽으면 넣을 수 있다.
4. **읽기(작업자 Reader)**: 서울신문 꼬리 'AI 퀴즈'·'이미지 확대', 이데일리 '가 가'·'주요뉴스', Scientific American 꼬리 구독 권유 상자 빼기.
5. **추출기**: SCMP·뉴스1 은 빠른 길이 일부/엉뚱한 상자를 얻고 멈춘다 — 출처별 느린 길 강제나 본문 선택자 규칙이 생기면 다시 넣기. KBS·YTN 은 사이트맵 받기 부담(하루 1천 건, 1.5MB/380KB)만 해결되면(출처별 받기 간격 등) 넣을 만하다.
