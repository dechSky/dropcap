# 읽기 창 본문 잘림 — 케이스별 분석과 대응·표시 제안 (2026-10-15, 맥)

> 상태: **5단계 반영(2026-10-16, carousel — 캐러셀·슬라이드 속 본문 글)** — 아래 '5단계 결과'. 4단계(paywall-early)·3단계(reader-phase3)·2단계 결과·1단계 분석은 그 아래에 그대로 둔다.

## 5단계 결과 (carousel)

1~4단계에서 '남음'이던 **Google 블로그 큰 발표 기사(65%)** 를 고쳤다. 받은 HTML 에 캐러셀 칸 글이 다 들어 있었다 — 3단계에서 '페이지 스크립트를 돌려야 잴 수 있다'고 본 것은 틀렸고, 인용 카드의 글이 요소 속성(`quote=`·`author-name=`·`author-title=`)에만 있어서 글자 수로 안 잡혔을 뿐이다.

### 고친 것

| 갈래 | 고침 | 규칙 이름(세 판 같은 이름) | 자리 |
|---|---|---|---|
| 캐러셀 칸이 통째로 빠짐(Google 블로그 `uni-media-carousel` 3개 22칸 — 영상 카드 설명 10 · 인용 카드 12) | 본문을 고른 뒤 원문에서 캐러셀(`aria-roledescription="carousel"`·swiper·glide·slick·splide·flickity·owl·class 에 carousel·`*-carousel` 요소)을 찾아, **앞 글과 뒤 글(문단·목록·소제목·인용)이 모두 우리 본문에 있는 것만** 칸(`aria-roledescription="slide"`·`swiper-slide`·`slick-slide`·`glide__slide`·`splide__slide`·`owl-item`·`carousel-item`·`*__slide`·`*-slide` 요소)마다 글·사진을 문서 순서대로 뒤 글 앞에 넣는다. 화면 밖 칸(aria-hidden)도 넣고, 복제 칸(`swiper-slide-duplicate`·`slick-cloned`·`cloned`·`--clone`)과 같은 칸은 한 번만, `data-swiper-slide-index` 가 다 있으면 그 차례로. 속성에만 든 인용(`quote=`·`data-quote=`, 20자 이상)은 인용 블록 + '— 이름, 직함' 문단. 사진 없는 칸의 설명 상자는 문단으로(짝 잃은 설명처럼 작게 보이지 않게). Readability 가 보이는 칸만 남겼으면(앞뒤 글 사이) 그것을 빼고 모든 칸을 차례대로 다시 넣음. 칸 안의 넘김 단추·점·쪽 번호는 뺌. 같은 글이 목차(li)에도 있으면 같은 태그의 것을 기준으로 | **carousel-slides** | 맥 추출 스크립트 · 윈도우 `web/extract.js` · 리눅스 `SCRIPT`(WebKitGTK) + `reader_extract::carousel`(웹 엔진 없는 빠른 길) |
| 안전장치(본문 밖 추천 캐러셀) | 넣지 않음: nav·header·footer·aside 안 · class 에 related·recommend·promo·popular·most-read·trending·ranking·newsletter · 첫 소제목이 'Related…'·'Read more'·'관련 기사'·'많이 본' 등 · 칸 글의 60% 이상이 링크(추천 기사 줄) · 앞 글이나 뒤 글이 본문에 없음(본문 앞뒤·옆 상자 — 매경 '기사 속 종목 이야기' 캐러셀은 본문 뒤라 그대로 빠짐) · 칸이 없는 'carousel' 상자 | carousel-slides | 같음 |

- 이전·되돌리기: 블록 꼴은 그대로(p·quote·img·cap)라 저장한 기사·다른 기기 기록에 영향 없음. 이미 받아 둔 기사는 그대로이고 '다시 받기'(⟳)나 다음 받기에서 새로 추림. 끄기는 추출 스크립트의 이 칸 하나를 빼면 됨.
- 세 판의 캐러셀 칸 스크립트는 글자째 같다(맥 `CarouselTests.sameBlockInAllThreeScripts` 가 들여쓰기만 빼고 견줌). 리눅스 빠른 길은 같은 순서·같은 기준의 Rust 판.

### 전·후

- 대상: Google 블로그 큰 발표 기사(blog.google/… — 1단계와 같은 기사), 같은 받은 HTML 을 고치기 전(bc75cc9)·후 맥 추출기 빠른 길로. 원문 글자 수는 1단계 웹 보기 측정(24,178자).

| | 전 | 후 |
|---|---|---|
| 우리 글자 / 원문 | 15,614 / 24,178 (**65%**) | 23,908 / 24,178 (**99%**) |
| 블록 | 54 | 88 (영상 카드 설명 문단 10 · 인용 12 + 말한 사람 12) |
| 빠진 것 | 캐러셀 칸 22개 전부 | 원문 쪽 각주 2문단(소개 가격 끝나는 날·'외부 의견' 고지 — `uni-footnotes`, 캐러셀 아님)·기자 직함 |

- 다른 출처: sources.json 피드마다 최신 1건(147곳 중 받은 115곳)을 받아 캐러셀 꼴을 찾음 — 본문 사이 캐러셀은 Google 블로그 3개뿐. 나머지는 메뉴(연합·SBS·JTBC 검색어 줄)·본문 옆·아래 추천 줄(Korea Herald·경향·동아·서울경제·서울신문·국민·매경 랭킹)·사진 보기 창(동아·서울경제)·BBC 세로 영상 줄(aside)·Guardian 'More on this story'·ESPN 점수 줄·Wired 상품 카드 사진 줄. 캐러셀이 있는 21쪽을 고치기 전·후로 추려 견주니 **바뀐 것은 Google 블로그 1쪽뿐**(추천 줄이 끼어든 쪽 0).

### 시험

- 맥 `Tests/DropcapTests/CarouselTests.swift`(6) · 윈도우 `ReaderCutCarouselTests`(5, `scripts/test-extract.sh` — 머리 없는 Chromium) · 리눅스 `tests/carousel_tests.rs`(5, 빠른 길).
- 실제 꼴: `Fixtures/reader-cut/carousel-cards.html`(Google 블로그를 `scramble_fixture.py` 로 — 이번에 `aria-roledescription`·`aria-hidden`·`data-swiper-slide-index` 를 남기고, 글이 든 속성 `quote`·`author-name`·`author-title` 은 글처럼 바꿔 남기게 고침). 표지: 앞 글 BEFORECAR · 첫 칸 CARCAPA · 인용 CARQUOTE + CARWHO · 마지막 칸 CARCAPZ · 뒤 소제목 AFTERCAR · 본문 밖 관련 기사 RELCAR. 리눅스는 같은 파일을 `tests/fixtures/reader-cut/` 에.
- 지어낸 HTML: swiper(화면 밖 칸·복제 칸·돌려 놓은 차례·쪽 번호·넘김 단추), slick 복제 칸, aria 캐러셀의 li 칸(사진+글), 추천 줄(링크 카드)·본문 뒤·aside 캐러셀은 안 넣음, 칸 없는 'carousel' 상자는 그대로.
- **고치기 전 실패**: 같은 시험을 고치기 전 추출기로 돌리면 세 판 모두 5개 중 3개 실패(Google 칸 설명·인용 없음, 화면 밖·복제 칸·차례, li 칸 사진·글) — 안전장치 2개는 전에도 통과(넣지 않는 쪽이라 당연). **고친 뒤 모두 통과.**
- 전체: 맥 `swift test` 341/341 · 리눅스 `cargo test` 313 통과(1 무시 — 바깥 서버) + 리눅스 전 기능 형 검사 · 윈도우 `dotnet test` 522 통과(8 건너뜀, 추출 JS 시험 포함) + WinUI 점검(`check-on-mac.sh`) 오류 0.


## 4단계 결과 (paywall-early)

1단계 ③ '목록·카드: 자물쇠 유지(열어 봐야 앎)'를 넓혀, **열기 전부터** 기사 단위로 알린다. 출처 단위 값(sources.json `paywall`·도메인 표·배운 막힘)보다 기사 단위 값을 앞세운다.

### 고친 것

| 갈래 | 고침 | 규칙 이름(세 판 같은 이름) | 자리 |
|---|---|---|---|
| 피드 단계 표시 | 피드가 기사마다 적은 유료 표시를 읽어 `NewsItem.paid`(true 유료 · false 무료로 풀림 · 없음): 분류(RSS `category`·`dc:subject`, Atom `category term`)가 `STAT+`·`Subscriber-Only Stories` 이거나 제목이 `STAT+:` 로 시작하면 유료, 분류가 `internal-paywall-exempt`(NYT)면 무료(둘 다면 무료). 유료면 `hard`(잠긴 자물쇠 '유료 기사'), 무료면 출처가 hard 여도 자물쇠 없음 — 무료 보도 고르기·맛보기 판정(hard 2,500자)에도 같은 값 | **feed-paid-mark** | `Core/FeedParser.paidMark` · `NewsItem.paid` · `Paywall.kind(paid:)` |
| 미리 받기 단계 판정 | 본문을 받은 기사(알림 뒤 미리 받기 R-16 포함 — 지금은 읽기 창만 남기던 것)마다 `Paywall.isTeaser` 결과를 DB `teasers(link, updated)` 에 남김(맛보기 아니면 지움 · 30일 · 2,000건 · 미래 시각 버림). 목록 줄·매거진 카드·표지·스토리·**물방울 알림**의 자물쇠가 **잠긴 자물쇠 + '앞부분만'(주황)** 으로 바뀜(다른 자물쇠는 기호만·회색). 미리 받기가 끝나면 떠 있는 물방울·목록도 바로 다시 그림 | **teaser-mark** | `Database.markTeaser`·`teaserLinks` · `PaywallBook.recordTeaser`·`teasers` · `ArticleService.run` · `UI/PaywallViews.PaywallMark` · `Toast/ToastView` |
| 판정 값 분리 | 맛보기 판정·읽기 창 안내에는 지난 판정을 뺀 값(`PaywallBook.sourceKind`)을 넘김 — '다시 받기'로 전문을 받으면 표시가 풀림. 판정 자체는 `Paywall.isTeaser` 그대로(Verge ld 길이 맞춤 포함) | – | `PaywallBook.sourceKind` · `ReaderView` |

### 피드에 표시가 실제로 보이는 곳(2026-10-16, sources.json 147개 피드를 받아 봄)

| 출처 | 피드 표시 | 결과 |
|---|---|---|
| STAT | 제목 머리 `STAT+: …`(이번 6건) + 분류 `STAT+`(5건) | 기사 단위 유료(출처 값은 metered) |
| MIT Technology Review | 분류 `Subscriber-Only Stories`(1건) | 기사 단위 유료(출처 값 metered) |
| NYT(건강 등) | 분류 `internal-paywall-exempt` | 무료로 풀린 기사 — 출처 hard 여도 자물쇠 없음 |
| 한경 3곳 | **없음** — 프리미엄9 도 주소 끝 `…i` 뿐이고 무료 기사도 같은 꼴(hk-it 기사 1·2), 요약·분류 칸 없음 | 피드로는 못 가림 → 미리 받기 판정(`articlePayment="Y"`+짧은 본문)으로 '앞부분만' |
| WSJ·Bloomberg·FT·Economist·Nikkei·Atlantic·Wired·MarketWatch | 없음(분류 없거나 주제뿐) | 출처 값 그대로 |
| SBS `스브스프리미엄` | 분류는 있으나 무료 기획 연재 | 표시로 쓰지 않음 |

### 남은 것

- **Google 블로그 캐러셀 속 인용**: 이번에도 손대지 않음(값어치 낮음 — 페이지 스크립트를 돌려야 잴 수 있음, 3단계 '남은 것' 그대로). → 5단계에서 고침(65% → 99%).
- 미리 받기는 알림 뜬 앞 3건만 하므로, 알림 없이 목록에만 있는 한경 프리미엄 기사는 열어 보기 전까지 출처 값(metered 열린 자물쇠)만 보인다.
- 이미 DB 에 있는 예전 피드 기사에는 `paid` 가 없다(다음에 받는 기사부터).
- (teaser-ld-port, 2026-10-16) 3단계 ld-body-match 를 윈도우·리눅스 맛보기 판정에도 옮김 — Verge 짧은 기사가 세 판 모두 '앞부분만'으로 뜨지 않음(윈도우 TeaserLdTests 6 · 리눅스 ld_body_tests 5).

### 시험

- `Tests/DropcapTests/PaywallEarlyTests.swift`(8): 피드 표시 있음(STAT+ 제목·STAT+ 분류·Subscriber-Only·Atom term)/풀림(exempt)/없음('Premium cars' 분류·제목 가운데 'STAT+:'), 기사 값이 출처·배운 막힘보다 앞섬, 무료 보도 고르기에 기사 값·맛보기 기록 반영, 예전 기록 읽힘, 맛보기 기록 DB(만료·미래 시각·지움), **미리 받기 맛보기 → 목록 표시 '앞부분만'**(앱 다시 켜도 남음 · 다시 받아 전문이면 풀림), Verge 꼴은 표시 안 됨. 글·주소는 지어냄.
- **고치기 전 실패**: 같은 시험을 고치기 전 코드(e30f0c6)로는 `Entry.paid`·`NewsItem.paid`·`PaywallKind.teaser`·`markTeaser` 가 없어 컴파일부터 안 됨 — 고치기 전 판정으로는 STAT+ 피드 기사가 출처 값 metered(열린 자물쇠 '일부 유료'), NYT 풀린 기사가 hard, 미리 받은 한경 맛보기는 목록에 아무 표시 없음. **고친 뒤 통과**, 전체 `swift test` 327/327.
- 화면 클릭 시험은 하지 않음(포커스를 뺏지 않게) — 자물쇠 표시는 `PaywallKind.shortText`·색 분기만.

## 3단계 결과 (reader-phase3)

### 고친 것

| 갈래 | 고침 | 규칙 이름(윈도우·리눅스 같은 이름) | 자리 |
|---|---|---|---|
| 사이트 HTML 은 앞부분만, 피드엔 전문(Politico) | 피드 `content:encoded`(RSS)·`content`(Atom, html)가 글 1,000자 이상이면 `NewsItem.feedBody` 에 둠(script·style·iframe·주석을 빼고 60,000자 상한 — 넘으면 마지막 `</p>` 에서 자름). 읽기 창은 피드 글이 추린 글보다 1.3배 넘게 길 때만 피드 본문을 한 번 더 추려 보고, **추린 본문의 긴 문단(40자 이상, 앞 6개) 앞머리 30자 가운데 60% 이상이 피드 글에 있으면**(같은 기사) 피드 본문을 씀. 사이트에서 아예 못 추렸으면(막힘·실패) 피드 본문이 300자 이상이면 그것을 씀 | **feed-full-body** | `Core/FeedParser.body` · `Reader/FeedFullBody` · `ArticleService.run` |
| 표(`<table>`) | 행마다 `row` 블록: 셀은 `cells` 에 따로, `text` 는 셀을 ' · ' 로 이은 글(찾기·요약·군더더기 규칙이 그대로 봄). 머리행 = `thead` 안·모두 `th`·첫 행 셀이 모두 굵은 글(AWS). 칸이 하나뿐이거나 사진·목록·소제목·중첩 표·400자 넘는 셀이 든 표는 자리 잡기용이라 안을 그대로 걸음. `<caption>` 은 설명(cap). 화면은 같은 폭 칸의 간단한 표(머리행 굵게·옅은 바탕, 줄 사이 가는 선) | **table-rows** | 추출 스크립트 `table` · `UI` `Reader/TableRowView` |
| 표 번역 | 셀 단위 묶음: `Translator.translateGroupsReporting` 이 묶음(행)마다 셀을 펴서 한 번에 보내고 같은 모양으로 돌려줌. 숫자·한국어 셀('20.3%')은 보내지 않음. 원문 보기는 원문을 ' · ' 로 다시 나눠 칸에 | **table-cell-translate** | `Core/Translator` · `ArticleService` |
| 사진 설명이 문단으로(경향·노컷·CNBC·NPR) | ① class 에 caption·cutline·credit·img_desc·photo_desc·desc_img·fr-inner 가 든 상자(사진·목록·소제목이 없고 400자 이하)는 Readability 전에 `figcaption` 으로 바꿔 둠(Readability 가 class·data-* 를 지워서 — figcaption 은 남음) → 걷기에서 설명(cap). ② class 없이 문단으로 온 출처 줄(150자 이하 — '… \| Getty Images'·'/AP'·'for NPR'·'Photo:'·'사진='·'… 제공/연합뉴스/뉴스1') 은 사진 바로 뒤면 설명으로(앞에 200자 이하 설명 문장이 끼어 있으면 둘 다), 사진 바로 앞이면(노컷) 사진 뒤로 옮겨 설명으로. ③ 이어진 설명은 ' · ' 로 하나로(설명+출처). figure 안 figcaption 이 여럿이면 모두 | **caption-pairing** | 추출 스크립트 |
| 본문 중간 추천 상자(ZDNet `.news_box`·Al Jazeera 'Recommended Stories') | 제목 글이 'Recommended Stories'·'Related …'·'Read more'·'More on this'·'Keep reading'·'관련기사'·'추천 기사'·'함께 볼 기사' 등(40자 이하)이고 바로 뒤 형제(또는 감싼 상자)가 **링크 글 60% 넘는 2,000자 미만 상자**면 제목+상자를 뺌. 모두 합쳐 페이지 글의 30% 미만일 때만(안전장치). 링크가 아닌 정리 목록은 그대로 | **inline-recommend** | 추출 스크립트(Readability 전) |
| Verge 짧은 기사 맛보기 오판(관리자 추가) | 사이트 ld+json `articleBody` 글자 수(`Article.ldBody` — 빠른 길은 받은 HTML 에서, 느린 길은 스크립트에서)가 우리 본문과 ±10% 이내면 '유료 표시+1,500자 미만' 규칙을 쓰지 않음. 우리 본문 길이는 그대로와 군더더기(기자 소개·'Follow topics…')를 뺀 길이 둘 다로 견줌. 하드 유료 2,500자·강한 문구·구독 권유 문구 판정은 그대로 | **ld-body-match** | `Core/Paywall.isTeaser(ldBody:)` · `ArticleExtractor.ldBodyLength` |

- 이전·되돌리기: `NewsItem.feedBody`·`Block.cells/head`·`Article.ldBody` 는 모두 없으면 nil(예전 DB json·다른 기기 기록·저장한 기사 그대로 읽힘). 예전 판은 새 json 의 모르는 칸을 무시하고, `row` 블록이 든 저장 기사는 예전 판에서 읽기 실패 → 다시 추림(캐시일 뿐).
- 크기: 받은 피드 10곳 1,141건 중 전문을 두는 것 67건(평균 10.6KB, Hugging Face 876건은 본문 없음). 읽기 창 목록이 한 번에 싣는 2,000건 기준 대략 수 MB.
- **저장에서 빼기(feedbody-trim)**: feedBody 는 피드 기록 DB 의 items 줄에만 남는다. `NewsItem.feedBody` 는 `@FeedBodyText` 로, 인코더 `userInfo[NewsItem.keepFeedBody]` 가 켜진 `Database.itemEncoder` 만 글을 쓰고 그 밖의 모든 저장(앱 상태의 최근·나중에 읽기·고인 소식, 스크랩·스크랩 사본, 백업, Spotlight)은 `"feedBody":null` — 저장하는 곳마다 비우지 않아도 새로 생기는 저장도 기본으로 빠짐. 본문 없는 사본으로 DB 에 다시 넣어도 DB 의 본문은 지우지 않음(upsert 의 CASE). 읽기 창은 사본에 없으면 DB 에서 key 로 다시 찾음. 같음·해시는 길이+앞 200자로(목록 비교가 60KB 를 훑지 않게). 예전 기록(칸 없음·글 그대로·null) 모두 읽힘. 상태 파일: 나중에 읽기 20 + 최근 20 + 고인 1건에 60KB 본문 → 전에는 약 2.4MB, 이제 30KB 미만(`FeedBodyTrimTests`).

### 전·후

- 대상: 각 출처 최신 1~2건(같은 사이트는 3초 간격, 1~2번만), 같은 받은 HTML 을 고치기 전(701e85a)·후 추출기로 빠른 길 추림(+ BodyCleanup). 기사 글은 기록하지 않고 숫자만.

| 출처 | 전 | 후 |
|---|---|---|
| Politico 일반 기사(1단계 측정과 같은 기사) | 사이트 1,078자(앞 4문단) | 피드 전문 4,358자(18블록) — 피드 6건 1,626~8,436자 모두 추려짐 |
| AWS ML(표 5개 기사) | 표 셀 89개가 한 줄짜리 문단으로 흩어짐(문단 164) | 표 행 24개(머리행 5), 흩어진 한 줄 문단 1 |
| AWS ML(표 1개 기사) | 한 줄 문단 15 | 표 행 3 |
| Hugging Face(벤치마크 표) | 셀 83개가 문단으로(문단 103) | 표 행 17(머리행 1), 문단 18 |
| 경향 2건 | 사진 설명 0(문단으로) | 설명 1·1 |
| 노컷 2건 | 설명 0 | 설명 1·2 |
| CNBC 2건 | 머리 사진 설명·출처가 첫 문단 2개 | 설명 하나(설명 · 출처) |
| NPR 2건 | 출처 줄('… for NPR' · '/AP')이 문단 | 사진 뒤 설명 |
| ZDNet 2건 | ①'관련기사'가 뒤쪽 절반에서 끝 자르기 표지로 걸려 **뒤 본문 2문단(235자)까지 잘림** ② 관련 기사 li 4개 섞임 | ① 상자만 빠지고 뒤 문단 살아남(1,943→2,178자) ② li 0(1,449→1,283자) |
| Al Jazeera 2건 | 받은 HTML(빠른 길)에서는 추천 상자가 빈 자리표시(`.recommended__loading`)라 이미 빠짐 | 같음 — 느린 길에서 채워진 상자는 같은 제목 규칙으로 빠짐(지어낸 꼴 시험) |
| Verge 짧은 기사(사용자 사례) | 맛보기로 판정(유료 표시+899자) — 띠가 잘못 뜸 | ld articleBody 902자 = 우리 899자 → 맛보기 아님 |

### 사례: The Verge 짧은 기사(맛보기 오판)

theverge.com/… — 사이트 HTML 본문 4문단과 ld+json articleBody(902자)가 같은, 원래 짧은 기사. Verge 는 늘 `isAccessibleForFree:false` 라고 적어 2단계의 '유료 표시+1,500자 미만' 규칙에 걸렸다. 추린 그대로는 기자 이름·소개·'Follow topics…' 까지 약 1,150자라 ld 와 27% 달라, 군더더기를 뺀 길이(899자)로도 견주게 했다. 그러면 사이트가 적은 본문 전부를 받은 것이므로 맛보기가 아니다. 사이트가 ld 에 전문을 적었는데 우리가 앞부분만 받았으면(ld 가 훨씬 김) 그대로 맛보기.

### 남은 것

- **Google 블로그 캐러셀 속 인용**(1건): 손대지 않음(→ 5단계에서 고침). 캐러셀(`uni-media-carousel`)은 영상 카드 설명이고 인용은 사용자 정의 요소 안이라, 받은 HTML 만으로 재려면 페이지 스크립트를 돌려야 함(이번 점검은 스크립트를 돌리지 않음). 값어치 낮음.
- 캐러셀 설명 상자(`__caption-within`)는 이제 class 규칙으로 설명(cap)이 됨 — 사진이 없으면 짝 잃은 설명처럼 작게 보임.
- 윈도우·리눅스: 위 규칙 이름(feed-full-body·table-rows·table-cell-translate·caption-pairing·inline-recommend·ld-body-match)으로 이식(각 담당).

### 시험(`Tests/DropcapTests/ReaderPhase3Tests.swift`)

- 실제 꼴(글·주소를 `scramble_fixture.py` 로 바꿈, `Fixtures/reader-cut/`): `table-rows`(AWS)·`table-thead`(HF)·`caption-p`(경향)·`caption-span`(노컷)·`caption-credit`(CNBC)·`credit-caption`(NPR)·`inline-related`(ZDNet — 제목 '관련기사' 낱말만 되살림, 기사 글 아님).
- 지어낸 HTML: 자리 잡기 표, 출처 줄 짝짓기(사진 뒤·앞), 끝말이 '제공'인 보통 문장은 그대로, 'Recommended Stories' 상자, 링크 아닌 'Related' 목록은 그대로, 피드 전문(파서·우선 판단·다른 기사·비슷한 길이), Verge 꼴(기자 소개·Follow 줄 포함), ld articleBody 읽기(@graph).
- **고치기 전 실패**: 같은 고정 HTML 을 701e85a 추출기로 돌리면 표 셀은 한 줄 문단으로, CAPMARK·CREDITMARK 는 문단(p)으로, RELMARK 관련 기사는 li 로 들어옴. Verge 꼴은 고치기 전 규칙(`paid && <1500`)으로 맛보기. 셀 묶음 번역·피드 전문·ld 길이는 고치기 전에 없던 기능. 첫 판 caption 표시(data-* 속성)는 Readability 가 지워서 CNBC 꼴이 실패 → figcaption 으로 바꿔 통과. Verge 는 군더더기를 뺀 길이로 견주기 전에는 실제 기사에서 여전히 맛보기(1,150 대 902) → 고친 뒤 아님.
- 전체 `swift test`: 아래 '완료' 보고에 적은 수.

## 2단계 결과 (결정 ①)

### 고친 것

| 갈래 | 고침 | 자리 |
|---|---|---|
| A 여러 덩어리 | Readability 결과의 첫 문단을 원문에서 찾아, 같은 꼴 형제(같은 태그+같은 첫 class·`data-block`·`data-component`, 또는 안에 같은 class 본문 상자가 든 형제 — Ars `div.my-2.5 > … > .post-content`)를 순서대로 모음. 글이 15% 넘게 늘거나, 글은 비슷한데 사진이 더 있으면(BBC 가 사진 블록을 버림) 모은 쪽. 관련·공유·광고·바이라인·머리 블록은 빼고 | `ArticleExtractor` 추출 스크립트 |
| A '일부만' | 본문 영역(itemprop·article)에 우리 글에 없는 긴 문단이 2개 넘게·25% 넘게 남으면 `partial` → 본문 끝 '본문 일부만 가져왔을 수 있어요 · 원문 열기 · 다시 받기' | 스크립트 · `CutEndNote` |
| B 옆 상자 | `itemprop="articleBody"` 가 있는데 고른 글이 그 밖이면 articleBody 를 씀(매경 'AI 종목 이야기' 상자) | 스크립트 |
| 동아 맨 글자 | `walk` 가 요소 사이 맨 글자도 모으고 `<br><br>` 에서 문단을 끊음(KR1·KR2) | 스크립트 |
| 연합 사진뿐 속보 | 기사 글 150자 미만인데 목록 글이 그 2배 넘으면 빈 본문 → '글이 거의 없는 기사' 안내(메뉴를 본문으로 내지 않음) | 스크립트 |
| 같은 글 두 벌 | 같은 글(30자 이상)·같은 사진은 한 번만 — 화면 크기별로 기사를 세 벌 싣는 Politico, 부제·사진 설명 중복 | 스크립트 |
| C 맛보기 판별 | `Paywall.isTeaser`: 지금 문구 판정 + 사이트가 유료라고 적음(ld+json `isAccessibleForFree:false`·한경 `articlePayment="Y"` — 빠른 길은 스크립트를 끄므로 받은 HTML 에서 직접 읽음) 이고 1,500자 미만 + 하드 유료 출처인데 2,500자 미만 + 끝쪽 강한 문구('exclusive to … subscribers'·'한경 프리미엄9의 모든 콘텐츠' 등, 길이 무관) | `Core/Paywall.swift` · `ArticleExtractor.paidFlag` |
| C 표시 | **본문 위 맛보기 띠**(무료 보도가 없어도 늘, 무료 보도 상자와 따로): '🔒 구독자만 전체를 볼 수 있는 기사예요 — 아래는 사이트가 공개한 앞부분입니다 [원문 열기]'. 본문 끝 '— 여기까지가 공개된 부분입니다 · 원문에서 이어 읽기 · 다시 받기'. 무료 보도 상자의 제목은 '다른 곳 보도로 전체를 읽을 수 있어요' | `UI/PaywallViews.swift` `TeaserBanner`·`CutEndNote` |
| M 캐시 | 맛보기·일부만 기사는 저장 6시간 뒤 다시 받음(저장 시각 없는 예전 기록도). 도구 막대 **'다시 받기'**(⟳) | `ArticleService.isStale`·`reload` |
| 군더더기 | 추출 전에 기자 소개 상자(`.author-mini-bio`·author-bio/box/card…)·댓글 수·공유 막대·단추·기자 페이지 링크 속 얼굴 사진을 뺌(페이지 글 30% 넘는 상자는 안 건드림). 추출 뒤 `BodyCleanup.junk`: 메일만·매체+메일·반응 단추·입력/수정일·저작권·'Follow topics…'·'Email (required)'·'N Comments'·오디오/영상 대체 문구·제휴 고지·뉴스레터·퍼가기 iframe 줄·도구 단추 글(기사 스크랩·공유·프린트), 머리 3블록·끝 4분의 1의 기자 소개 문장(+바로 앞 이름 줄), 잇단 같은 글. **끝 자르기**는 뒤쪽 절반의 표지(관련 기사·More on this story·많이 본 뉴스·저작권 줄)부터, 지울 글이 본문의 20%(저작권 줄이면 50%) 이하일 때만. 줄 규칙은 160자 이하 줄만, 한가운데서 20% 넘게 지우게 되면 가운데 것은 둠. 번역 전에 빼서 번역 시간도 줄임 | 스크립트 · `Reader/BodyCleanup.swift` · `ArticleService` |
| 작은 그림 | 480pt 미만 그림은 본래 폭까지만(작은 원형 기자 사진을 본문 폭으로 키우던 것) | `ReaderView` `ImageFit` |
| 번역 인계(TRANSLATE.md 6·7·9·1) | 각주 `<sup>` 숫자 빼기, `<br>` → 빈칸, 'hide/toggle caption' 단추 글 빼기, 퍼가기 iframe 줄 빼기, 같은 문장 두 블록 한 번만, **문단별 원문 펼치기**(번역 문단에 마우스를 올리면 왼쪽 '원문' 단추·오른쪽 클릭 '이 문단 원문 펼치기', 번역문 아래 작게) | 스크립트 · `ReaderView` |
| 흘려 주기(5) | Translator 의 기기 내 흘려 주기 API 가 아직 없어 연결하지 않음 — 작업자 Translate 에 꼴을 물어 둠(tell) | – |

### 전·후 (같은 기사)

- 대상: 1단계 238건에서 봇 확인에 걸리는 NYT·WSJ·MarketWatch 16건을 뺀 222건(같은 날 여러 번 치면 막힘). 전 = 1단계 측정, 후 = 9c8acc7 로 222건 전부 + f5c8d57 로 바뀐 출처 82건 다시(Politico·한경·연합·매경·Verge·Ars·BBC·동아), BBC 사진은 92d7373 로 14건.
- 받기 성공 204/206 → 204/206(같음 — 실패 2건은 BBC 영상 페이지·한겨레 1건으로 전과 같음). 비교 불가(지역 언어) 4건 제외.

| 1단계에서 잘림 확정 10건 | 전 우리/원문 | 후 우리/원문 |
|---|---|---|
| Ars — 꿀벌 침 기사 | 2,187 / 4,597 (48%) | 4,224 / 4,597 (92%) |
| Ars — 캐릭터 AI 기사 | 2,699 / 6,724 (40%) | 6,457 / 6,724 (96%) |
| Ars — Play 스토어 기사 | 1,907 / 3,963 (48%) | 3,498 / 3,963 (88%) |
| Ars — FTC 기사 | 2,251 / 4,622 (49%) | 4,261 / 4,622 (92%) |
| Ars — 에뮬레이터 기사 | 2,183 / 4,111 (53%) | 3,787 / 4,111 (92%) |
| BBC Health — 보철 기사 | 1,217자 · 사진 0 | 6,187자 · 사진 5 (앞부분 빠짐 해소) |
| BBC Science — 사진전 기사 | 1,464자 · 사진 0 | 7,914자 · 사진 18 (사진별 설명 전부) |
| 매일경제 증권 | 499 / 1,326 (38%, 옆 상자) | 1,312 / 1,326 (99%, 본문) |
| Politico | 1,003 / 2,909 (34%) | 1,274 / 2,909 (44%) — **남음**(아래) |
| Google 블로그 큰 발표 | 15,866 / 24,178 (66%) | 15,614 / 24,178 (65%) — **남음**(캐러셀) |

- Ars 의 '빠진 1문단'은 원문 쪽 기자 소개(우리가 일부러 빼는 것) — 본문은 다 옴. BBC 는 웹 보기 측정이 본문 영역을 못 잡아(원문 글자 2) 원문 HTML 과 대조로 확인.
- 동아 9건: 655→1,414 · 1,375→2,193 · 1,093→1,635 · 2,175→2,857 · 487→964 · 568→687 · 892→1,457 · 517→880 · 599→920자(맨 글자 리드·중간 문단 살아남).
- BBC 사진: 고유 기사 11건(영상 페이지 제외) 중 전 0건 → 후 7건에 사진(1~18장). 주요 뉴스 2·스포츠 2 는 여전히 0 — 원문 꼴은 아직 안 봄(다음 묶음).
- 군더더기: 206건 중 95건에서 8,717자를 뺌(한 기사 평균 92자). 한 기사에서 20% 넘게 뺀 것은 3건 — 한경 맛보기 2건(도구 단추·입력일·프리미엄 고지)과 연합 북한 1건(메일·제보 줄, 21%) — 모두 군더더기 줄이고 기사 문단은 아님.
- 맛보기 표시: 전 1건(STAT, 안내 없음) → 후 3건(STAT+ 1·한경 프리미엄9 2) 모두 띠·끝줄. WSJ(hard)·NYT 는 이번에 못 받아 확인 못 함 — 규칙상 WSJ 는 hard+짧은 본문으로 걸림.
- 오판(무료 기사를 맛보기로): 0건. Verge(사이트가 isAccessibleForFree=false 라고 적지만 전문을 줌, 1,900~3,700자)는 1,500자 기준 아래가 아니라 걸리지 않음.

### 사용자 사례: The Verge(유료처럼 잘려 보임)

theverge.com/…

| | 고치기 전 앱 | 고친 뒤 |
|---|---|---|
| 본문 | 빠른 길 1,989자·9블록 — 기사 문단 6개는 다 옴(웹 보기의 기사 영역 2,511자 중 빠진 3문단 245자는 부제·사진 설명) | 같음 |
| 맨 앞 | **기자 얼굴 사진 + 이름 + '…is a news writer who covers…' 소개 2문단** — 기사가 소개글로 시작해 '뭔가 잘린' 인상(사진은 그전에도 isJunk 로 숨김) | 얼굴 사진은 추출에서 빠지고, 이름·소개 2블록은 군더더기 규칙(머리 3블록의 기자 소개 + 앞 이름 줄)으로 빠짐 → 기사 첫 문단부터 |
| 맨 끝 | 'Follow topics and authors…' + 기자 이름 목록 | 빠짐 |
| 맛보기 안내 | 없음(`looksBlocked` 아님) | 없음 — 사이트가 전문을 줌(isAccessibleForFree=false 지만 1,989자 ≥ 1,500 기준이라 맛보기 아님) |
| 자물쇠 | 없음(sources.json `verge-all` paywall 값 없음, knownDomains 에도 없음) | 같음 — **metered 로 바꾸는 것은 Sources 담당 인계**(INTL1·INTL2 제안) |

결론: 이 기사는 **잘린 것이 아니라 짧은 기사 앞뒤에 기자 소개·팔로우 권유가 붙어** 잘린 것처럼 보였다. 군더더기 규칙으로 고쳐짐.

### 정책 표(출처 점검 _INTL1·_INTL2·_KR1·_KR2 합침)

| 문제 | 출처(점검) | 처리 | 상태 |
|---|---|---|---|
| 본문 여러 덩어리 | Ars·BBC 4~6곳(INTL1·2) | 형제 덩어리 모으기(A) | ✅ |
| 본문 사진 빠짐 | BBC 4곳 | 모은 쪽에 사진이 더 있으면 그쪽 | ✅(고유 11건 중 7건) |
| 옆 상자·AI 패널 | 매경(KR1·2) | articleBody 우선(B) | ✅ |
| 맨 글자 문단 버림 | 동아 4~5곳(KR1·2) | walk 맨 글자 | ✅ |
| 사진뿐 속보에 페이지 전체 | 연합(KR1) | 목록뿐이면 '글 거의 없음' | ✅ |
| 짧은 기사에 목록·꼬리 | KR2 7곳 | 같은 규칙(목록이 글의 2배) + 끝 자르기 | 부분 — 글이 150자 넘으면 그대로 |
| 화면별 여러 벌 | Politico | 같은 글 한 번만 | ✅ |
| 사이트 HTML 이 앞부분만(피드엔 전문) | Politico(INTL1) | 피드 전문 보관·우선(feed-full-body) | ✅ 3단계 |
| 캐러셀 속 인용 | Google 블로그 | — | **남음**(1건, 값어치 낮음 — 3단계 '남은 것') |
| 표(`<table>`) 셀이 한 줄 문단으로 흩어짐 | AWS·Hugging Face | 행 블록·셀 번역(table-rows) | ✅ 3단계 |
| 사진 설명이 문단으로 | 경향·노컷·CNBC·NPR | 설명 상자·출처 줄 → cap(caption-pairing) | ✅ 3단계 |
| 맛보기(STAT+·한경 프리미엄9·하드) | STAT·한경 3곳·WSJ·FT 등(ADD) | isTeaser + 띠·끝줄 | ✅ |
| paywall 값 틀림 | Verge·MIT TR→metered, 한경→metered, NYT→hard, MarketWatch→hard(INTL1·2·KR1) | — | **Sources 담당**(shared/sources.json) |
| 기자 소개·얼굴 사진·댓글 수 | Ars·Verge·TechCrunch·Inside Climate·한경·코메디 | 상자 빼기 + 소개 문장 줄 + 작은 그림 안 키움 | ✅ |
| 저작권·메일만·제보 줄 | 연합 7·SBS·동아·한경·서경·코메디(19곳) | 줄 규칙 + 끝 자르기 | ✅ |
| 반응·공유·도구 단추 글 | 동아·한경·서경·코메디 | 줄 규칙 | ✅ |
| 오디오·영상 대체 문구 | 한겨레·전자신문·Google·DW | 줄 규칙 | ✅ |
| 입력·수정일 줄 | 한경·서경·전자신문 | 줄 규칙 | ✅ |
| 관련·추천·많이 본 목록 | Anthropic·Guardian·Quanta·한경·ZDNet·노컷 | 끝 표지 자르기(뒤쪽 절반) | ✅ 3단계 — 본문 중간 추천 상자도(inline-recommend) |
| 각주·br·사진 단추 글·iframe·중복 | 번역 인계 | 스크립트·줄 규칙 | ✅ |
| 추적 픽셀·아이콘 svg | ScienceDaily·전자신문 | 기존 isJunk(`/icons?/`·`pixel.`·`1x1`) | 부분 — `count.gif` 꼴은 남음 |
| 일본어판 섞임 | 조선 전체(KR1) | — | Translate·Sources 담당 |

### 시험

- `Tests/DropcapTests/ReaderCutTests.swift`(17): 실제 페이지 꼴 4종(`Fixtures/reader-cut/` — Ars·BBC·매경·동아의 태그·class 만 남기고 글·주소를 바꾼 것, `scripts/scramble_fixture.py`) + 지어낸 HTML(덩어리·BBC·매경 AI 상자·동아 br·유료 표시·연합 속보·각주/br/사진 단추·Politico 세 벌) + 규칙(맛보기·군더더기·안전장치·작은 그림·캐시 수명).
- **고치기 전 실패**(같은 시험을 고치기 전 코드로): 실제 꼴 Ars 리드 빠짐·BBC 끝 빠짐·동아 리드 빠짐, 매경 AI 상자 섞임, 유료 표시 없음, 연합 속보에 메뉴, 각주 붙음·br 붙음·hide caption, 맛보기·군더더기·작은 그림·캐시 규칙 모두 실패 → **고친 뒤 통과**. 전체 `swift test` 275/275.
- 화면: 맛보기 띠·무료 보도 상자·끝줄을 창 없이 그림으로(`ImageRenderer`, `READER_CUT_SHOT_DIR` 줄 때만 — 포커스를 뺏지 않음) 무료 보도 있음/없음 두 경우 확인. 실제 창 클릭 시험은 하지 않음.



사용자 증상: ① 유료 기사에서 내용이 잘림 ② 유료가 아닌 기사도 본문이 다 나오지 않을 때가 있음.

## 한 줄 결론

- **유료 아님 잘림은 실재한다: 잴 수 있었던 216건 중 10건(4.6%).** 원인은 거의 하나 — **본문이 광고·사진을 사이에 두고 여러 덩어리로 나뉜 페이지에서 Readability 가 한 덩어리만 고름**(Ars Technica 5·BBC 2·Politico 1·Google 블로그 1), 그리고 **본문 대신 옆 상자를 고름**(매일경제 1). 대개 **앞부분이 통째로 빠져 기사 중간부터 시작**해서 사용자가 알아채기 어렵다.
- **유료 잘림은 '맛보기'를 아무 안내 없이 보여 주는 문제다.** STAT 맛보기(1,455자)는 앱도 '맛보기'로 알아챘지만(`paywalled`) 같은 소식 무료 보도가 없어 **안내가 전혀 안 나왔다**(`freeReason` 은 무료 보도가 있을 때만). WSJ(600~730자)·NYT(1,000~2,600자)도 맛보기로 보이나 앱이 맛보기로 판정조차 못 한다.
- 번역·화면·2MB 상한·기자 줄 빼기(BodyCleanup)로 인한 잘림은 **0건**.

## 잰 방법

- 대상: READSWEEP 과 같은 238건(기본 출처 119곳 × 최신 2건, `readsweep/sweep-after.md` 의 주소).
- 우리 본문: 앱과 같은 `ArticleExtractor().extract(allowScripts: true)` 결과에서 읽기 창이 빼는 기자 줄·짝 잃은 설명(`BodyCleanup`)을 뺀 글자 수.
- 원문 본문: 같은 기사를 웹 보기에 스크립트까지 다 띄우고(그림·영상·글꼴만 막음) **Readability 와 다른 방법**으로 본문 영역을 골라 보이는 글자 수를 잼 — `itemprop="articleBody"` → 가장 안쪽 `<article>` → 보이는 문단이 가장 많이 몰린 곳. 그 영역의 60자 넘는 문단마다 우리 글에 들어 있는지도 봄(앞·중간·끝 조각 대조).
- 잘림 판정: 우리 글 / 원문 글 < 70% 이거나 빠진 문단 글자가 원문의 30% 넘음 → 원문 HTML 을 한 번 받아 **사람이 대조해 확정**.
- 유료벽 신호: ld+json `isAccessibleForFree`, 보이는 글의 구독 권유 문구, paywall·piano 꼴 요소.
- 다시 돌리기: 아래 '다시 돌리는 법'. 기록에는 숫자·주소만 남기고 기사 글은 남기지 않는다.

### 측정에서 고친 것(오판 막기)

- **끝까지 내리면 다음 기사가 이어 붙는 사이트**(TechCrunch·ESPN·ZDNet·블로터): 처음엔 이어 붙은 다음 기사까지 원문으로 세어 9건을 잘림으로 잘못 봤다 → 내리지 않고, 문서 순서로 첫 본문 영역을 쓰게 고친 뒤 다시 재니 모두 정상(97~105%).
- OpenAI·AWS 는 웹 보기에서 한국어 페이지(`/ko-KR/`)로 넘어가 비교 불가(우리 본문은 영어 원문으로 정상) → 제외 4건.

## 전체 숫자 (238건)

| 구분 | 건 | 비고 |
|---|---|---|
| 잴 수 있었음 | **216** | 238 − 받기 실패 18 − 비교 불가(지역 언어) 4 |
| └ 다 왔음(≥70%·빠진 문단 없음) | 205 | 판정에 걸렸다가 대조해 보니 정상인 16건 포함(아래 '오판' — 판정 27건 중 11건만 실제) |
| └ **잘림 확정(유료 아님)** | **10** | 케이스 A·B |
| └ **유료 맛보기** | **1** | STAT(케이스 C) |
| 받기 실패 | 18 | 봇 확인 16(NYT 12·WSJ 2·MarketWatch 2), 영상 페이지 1(BBC), 한겨레 1 |
| 비교 불가 | 4 | OpenAI 2·AWS 2(지역 언어 페이지) |

받기 실패 16건은 **이번 측정이 같은 사이트를 여러 번 친 탓**이다(NYT·WSJ·MarketWatch 는 DataDome 봇 막기 — 어제 READSWEEP 에서는 모두 열렸고, 오늘 시범 측정 뒤부터 확인 문제 페이지(1.5KB)만 옴). 그래서 이 셋의 맛보기 여부는 **어제 기록(글자 수)으로만** 본다.

## 케이스 표

| # | 케이스 | 건 | 대표 주소 | 판별 신호(어떻게 알아채나) |
|---|---|---|---|---|
| **A** | **본문이 여러 덩어리 — Readability 가 한 덩어리만** | **9** (Ars 5·BBC 2·Politico 1·Google 1 — Ars·BBC 는 원문 HTML 대조로 확정) | arstechnica.com/… (48%: 앞 4문단 빠짐, 정적 HTML 에 10문단 다 있음) · bbc.co.uk/… (소개 8문단만, 사진별 설명 수십 문단 빠짐) · politico.com/… (34%) · blog.google/… (66%, 중간 11문단) | 고른 덩어리의 부모 아래에 **같은 꼴(태그·class)의 형제 덩어리**가 더 있고 그 안에 긴 문단이 있음. 결과의 첫 문단이 기사 첫 문단(og:description·피드 요약과 겹침)과 다름 |
| **B** | **본문 대신 옆 상자를 고름** | 1 (매일경제) | mk.co.kr/… (우리 499자 = 'AI 종목 이야기' 상자, 실제 본문 1,326자) | HTML 에 `itemprop="articleBody"`·ld+json `articleBody` 가 있는데 우리 결과와 겹치지 않음 |
| **C** | **유료 맛보기(하드·구독)** | 1 확정(STAT) · 추정 14(WSJ 2·NYT 12) | statnews.com/… (1,455자, 끝이 'Subscribe') · WSJ 어제 600·731자(4~6문단) · NYT 어제 1,023~2,648자 | ld+json `isAccessibleForFree: false` + 짧은 본문, 구독 권유 문구, sources.json `paywall`(hard·metered). 지금 앱 판정 `Paywall.looksBlocked` 는 **1,500자 미만 + 문구 16개**뿐이라 WSJ·NYT 는 못 잡음 |
| D | 무료 건수 제한(metered) | 0 잘림 · 신호 9 (Verge 4·STAT 2·한국경제 2·MIT TR 1) | theverge.com/… | `isAccessibleForFree: false` 인데 본문은 다 옴. 느린 길 웹 보기가 **비영속 저장소**라 매번 '첫 방문자'로 보여 건수가 차지 않음 → 지금은 문제 아님 |
| E | 로그인·가입벽 | 0 | – | 탐지 13건(노컷 등)은 모두 **댓글 로그인 안내**를 잘못 잡은 것, 본문은 다 옴 |
| F | 지연 로딩·'더 보기' | 0 | kormedi.com/… ('더 보기'는 댓글 단추, 본문 1,403자 중 1,273자 옴 = 다 옴) | 본문 영역 안 '더 보기'·'Read more' 단추. 이번 목록에는 본문을 접는 사이트 없음 |
| G | 여러 쪽 기사 | 0 | – | `rel=next`·쪽 번호 — 이번 목록 0 |
| H | 페이지 2MB 상한 | 0 | – | 상한을 넘으면 잘리는 게 아니라 **받기 실패 → 느린 길**로 감(`FeedService.collect` 가 `tooLarge` 던짐). 이번 238건 중 넘는 것 0 |
| I | BodyCleanup(R-21)·hiddenBlocks 과잉 | 0 | – | 기자 줄·짝 잃은 설명으로 뺀 글 46건 합계 982자, 한 기사에서 20% 넘게 뺀 일 0 |
| J | 번역 단계 문단 빠짐 | 0(코드 확인) | – | `ArticleService` 는 문단 수를 그대로 두고 자리마다 바꿔 끼움. 구글 묶음 번역은 돌아온 문단 수가 안 맞으면 문단별로 다시, 실패한 문단은 원문 그대로 → 빠지지 않음 |
| K | 화면 렌더 제한 | 0(코드 확인) | – | `articleBody` 는 블록 전부를 그림(개수·줄 제한 없음) |
| L | 봇·지역 차단 | 16(측정 탓) | nytimes.com/… | 받은 페이지가 1.5KB 안팎·captcha-delivery. 지금은 '막힌 사이트' 실패 안내로 감(잘림 아님) |
| M | **캐시에 남은 잘린 본문**(코드 확인) | – | – | `ArticleService.cached` 는 한 번 '완료'된 기사를 디스크에 150건까지 두고 **다시 받지 않음**. 맛보기·잘린 결과도 그대로 남아, 사이트가 고쳐지거나 앱이 고쳐져도 그 기사는 계속 잘려 보임. '다시 받기' 단추 없음 |

### 오판(판정에 걸렸지만 대조해 보니 정상) — 16건

| 까닭 | 건 | 예 |
|---|---|---|
| 원문 쪽이 다음 기사까지 셈(무한 스크롤) | 9(측정 고친 뒤 다시 재서 해소) | TechCrunch 4·ESPN 2·ZDNet 2·블로터 1 |
| 원문 영역을 못 찾아 페이지 전체를 셈 | 2 | 코메디닷컴 2 |
| 원문 영역이 쿠키 안내 | 2 | NVIDIA 2(우리 본문 6,295·17,476자로 정상) |
| 실제로 짧은 기사·소개 페이지 | 3 | 전자신문 포토(103자)·blumify·동아 연예(태그 줄) |

곁가지(잘림 아님, 넘침): 본문 끝에 잡글이 붙는 사이트 — 'Email (required)'(Verge), 'View Bio'(TechCrunch), 태그 목록·저작권·기자 소개·'댓글'(코메디닷컴), '지금 뜨는 뉴스'(동아). 별도 작업 후보.

## 케이스마다 제안

### A. 본문이 여러 덩어리 (9건, 유료 아님 잘림의 90%)

① 대응
- **①-1 형제 덩어리 합치기(추천)**: Readability 결과의 첫 문단을 원문 문서에서 찾아 그 덩어리의 부모로 올라가, **같은 태그·같은 class** 의 형제 가운데 긴 문단(80자 이상)이 든 것을 문서 순서대로 합친다. 합친 글이 1.2배 넘게 길 때만 바꿈. related·share·aside 안은 제외. 비용: 추출 스크립트 30줄 안팎 + 시험(Ars·BBC 꼴 고정 HTML). **`ArticleExtractor.swift` 의 추출 스크립트(71~86줄: `new Readability(doc).parse()` 바로 뒤)를 고쳐야 함 — mac-security-low 작업자가 같은 파일(느린 길 content rule)을 고치는 중이라, 결정이 나면 그쪽 병합 뒤에 하거나 스크립트를 `Reader/` 의 새 파일로 옮기는 2줄만 그 파일에서 바꾸는 쪽으로 조율 필요.**
- ①-2 사이트별 선택자(Ars `.post-content`·BBC `[data-component=text-block]`·Politico `.story-text`): 싸고 정확하나 사이트가 바뀌면 깨지고 목록 밖 사이트는 못 고침.
- ①-3 그대로 두고 ②의 안내만.

② 읽기 창 표시: 고친 뒤에도 못 합친 경우를 위해, 본문 끝에 **'본문 일부만 가져왔을 수 있어요 · 원문 열기'** 한 줄(작게, 회색) — 판별 신호(형제 덩어리가 남음·첫 문단이 피드 요약과 안 겹침)가 있을 때만.

③ 목록·카드: 표시 없음(사이트 단위로 늘 잘리는 게 아님).

④ 판별이 틀릴 때: 합치기가 관련 기사·사진 설명 묶음을 본문으로 붙일 수 있음 → class 같음 + 긴 문단 + 1.2배 조건, related 제외로 막고, 시험에 '같은 class 의 관련 기사 상자' 꼴을 넣음.

### B. 옆 상자를 고름 (1건)

① 대응(추천): HTML 에 `itemprop="articleBody"` 또는 ld+json `articleBody` 가 있고 Readability 결과와 **겹치지 않으면** 그쪽을 씀(`EmbeddedArticle` 이 이미 ld+json 을 읽음 — 맥 `Reader/EmbeddedArticle.swift` 안에서 '겹침 검사' 함수를 더하고, 부르는 자리 1곳은 ArticleExtractor). 비용 작음.
② 표시: A 와 같은 '일부만' 안내를 같이 씀.
④ 위험: ld+json articleBody 가 요약만 든 사이트 → 길이가 Readability 결과보다 길 때만 바꿈.

### C. 유료 맛보기 (STAT 확정 · WSJ·NYT 추정)

① 대응: 맛보기 자체는 못 고침(구독 쿠키 없음, 비영속 웹 보기). **판별을 넓히는 것**이 할 일.
- **①-1 판별 넓히기(추천)**: 맛보기 = `looksBlocked`(지금) **또는** ld+json `isAccessibleForFree: false` 이면서 본문 2,500자 미만 **또는** 출처가 `paywall: hard` 이면서 본문 2,500자 미만. `isAccessibleForFree` 는 빠른 길 HTML 에서 읽어야 하므로 `ExtractTrace` 에 칸 하나(ArticleExtractor 3줄 — 결정필요 대상). 문구 목록에 'subscribe now'·'subscribe' 단독 끝줄 추가.
- ①-2 문구 목록만 늘림(ArticleExtractor 안 건드림): STAT 은 이미 잡히고 WSJ·NYT 는 여전히 못 잡을 수 있음.

② 읽기 창 표시(관리자 지적 그대로 — **무료 보도 상자와 따로**)
- **②-1 본문 위 띠(추천)**: 맛보기로 판정되면 **무료 보도가 없어도** 본문 바로 위(표지·제목 아래)에 눈에 띄는 띠:
  `🔒 구독자만 전체를 볼 수 있는 기사예요 — 아래는 사이트가 공개한 앞부분입니다.  [원문 열기]`
  무료 보도가 있으면 그 아래에 지금의 '같은 소식을 무료로 읽기' 상자를 이어 붙임(따로 두 개). 본문 **끝**에도 `— 여기까지가 공개된 부분입니다 · 원문에서 이어 읽기` 한 줄(맛보기가 끝난 자리를 알려 줌).
- ②-2 끝줄만: 덜 눈에 띔 — 사용자가 '잘렸다'고 느낀 뒤에야 봄.
- ③ 목록·카드: 지금 자물쇠(G-14) 유지. 열어 보고 맛보기로 판정된 기사는 PaywallBook 이 이미 쌓으므로(learned) 추가 표시 불필요.
- ④ 위험: 짧은 무료 기사(단신)를 유료로 잘못 띄움 → 출처 `paywall` 표시나 `isAccessibleForFree: false` 가 있을 때만 길이 조건을 씀(문구만으로는 1,500자 미만일 때만 — 지금과 같음). 이번 238건에서 그 조건이 맞는 기사는 STAT 1·WSJ 2·NYT 12 뿐이고 무료 기사 오판 0.

### D. 무료 건수 제한 — 대응 없음(지금 문제 아님)

비영속 웹 보기라 건수가 차지 않음. 나중에 로그인 쿠키를 쓰는 기능을 넣으면 그때 C 의 판별이 같이 잡음. **추천: 그대로.**

### E·F·G. 로그인벽·더 보기·여러 쪽 — 이번 목록 0건

대응은 만들지 않고 점검 장치(`ReadFull`)가 계속 셈. 생기면 F 는 느린 길에서 '더 보기' 단추를 눌러 펼친 뒤 추출(비용 중), G 는 다음 쪽을 이어 받기(비용 중). **추천: 보류.**

### H·I·J·K. 2MB·다듬기·번역·화면 — 0건, 대응 없음

### L. 봇·지역 차단 — 이미 실패 안내(READSWEEP 고침)로 감. 대응 없음.

### M. 캐시에 남은 잘린 본문

① **추천: 맛보기·'일부만' 판정된 기사는 캐시 수명을 짧게(예: 6시간)** + 읽기 창 메뉴에 **'다시 받기'**(캐시 지우고 다시 추리기). 비용 작음(`ArticleService`·`ReaderView`, 담당 범위 안).
② 표시: '다시 받기'는 ⋯ 메뉴에, A·C 의 띠에도 작은 '다시 받기' 링크.
④ 위험: 거의 없음(다시 받는 비용뿐).

## 결정 요청

| 선택지 | 내용 | 비용 | 고치는 것 |
|---|---|---|---|
| **① (추천)** | A 형제 합치기 + B articleBody 겹침 검사 + C 판별 넓히기(`isAccessibleForFree`) + **C 본문 위 띠(무료 보도 상자와 따로)·끝줄** + M 짧은 캐시·다시 받기 | 중 — ArticleExtractor 추출 스크립트·trace 수정 필요(mac-security-low 와 순서 조율) | 유료 아님 잘림 10/10, 맛보기 안내 1+14 |
| ② | 표시만: C 띠·끝줄(지금의 `paywalled` + 출처 hard·짧은 본문으로 판정) + M 다시 받기 + A·B 는 '일부만' 안내 없이 그대로 | 작음 — ArticleExtractor 안 건드림 | 맛보기 안내(STAT·WSJ·NYT), 유료 아님 잘림은 그대로 |
| ③ | ① 에서 A 를 사이트별 선택자(Ars·BBC·Politico)로 | 작음~중 | 목록 안 9건만 |

2단계 시험(결정 뒤): Ars·BBC·Politico·매일경제·STAT 꼴 고정 HTML 로 '고치기 전 실패 → 고친 뒤 통과', 맛보기 띠는 무료 보도 있음/없음 두 경우 화면 확인(포커스 뺏지 않는 시험 창), 같은 238건 다시 재기(NYT·WSJ·MarketWatch 는 하루 띄워서).

## 다시 돌리는 법

```sh
cd mac && swift build
OUT=$(mktemp -d)
DROPCAP_DATA_DIR=$(mktemp -d) DROPCAP_TEST_READSWEEP=$OUT DROPCAP_TEST_READSWEEP_LABEL=full \
  DROPCAP_TEST_READSWEEP_FULL=1 DROPCAP_TEST_READSWEEP_REPLAY=<앞 점검 json> .build/debug/Dropcap   # 238건 약 50분
```

- `DROPCAP_TEST_READSWEEP_FULL=1`: 기사마다 원문을 한 번 더 띄워 완전성(`FullCheck`)을 잼. 출처마다 첫 기사들을 먼저 돌고 같은 사이트는 20초 띄움.
- `DROPCAP_TEST_READSWEEP_SCROLL=1`: 원문을 끝까지 내려 늦게 그리는 글까지(무한 스크롤 사이트에선 다음 기사가 섞이니 주의).
- `DROPCAP_TEST_READSWEEP_DUMP=<폴더>`: 추린 블록을 그대로 남김 — **기사 글이 들어가므로 저장소에 넣지 않는다.** `FullCheck.debugMiss` 도 로컬 진단 전용.
- NYT·WSJ·MarketWatch 는 같은 날 여러 번 돌리면 봇 확인에 걸린다.
