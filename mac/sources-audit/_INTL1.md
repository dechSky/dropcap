# 출처 점검 INTL1 — 묶음 요약

- 점검일 2026-10-15 · 출처 25곳 · 기사 75건(출처마다 3건: 최신 · 피드 글이 가장 긴 것 · 짧은 글/속보 후보) · 차단 4곳(nyt-politics, marketwatch, nyt-business, nyt-home)
- 판정: 좋음 5 · 부분 13 · 나쁨 7
- 앱 대조: 같은 75건을 실제 앱(DROPCAP_TEST_READSWEEP 점검 모드, 창 없음)으로 다시 돌려 얻은 길·글자 수가 재현과 61/75 일치(10% 안). 나머지 14건은 받기 차이(앱 URLSession 은 New Scientist·Politico 를 빠른 길로 받고, 점검 도구 node 는 406·403) 또는 NYT 차단 시점 차이 — 표의 '얻은 길'은 앱 값.

## 출처별

| 출처 | 판정 | 완전성 중앙값(사이트 글 중 있는 비율) | 주요 문제 | 제안 규칙 |
|---|---|---|---|---|
| [Anthropic](anthropic.md) `anthropic` | 부분 | 100% | 본문·사진·설명은 100% 맞음. 다만 2/3 기사 끝에 "Related content"(다른 글 3개의 제목·요약)가 본문으로 섞임. | "Related content" 머리부터 뒤 자르기 |
| [Ars Technica](ars-all.md) `ars-all` | 나쁨 | 55% (최저 53%) | 본문이 광고 칸을 사이에 둔 `.post-content` 여러 덩어리인데, Readability 가 그중 한 덩어리만 골라 2/3 기사에서 앞이나 뒤 절반(문단 3~5개·소제목)이 빠짐. | `.post-content` 덩어리 모두 순서대로 모으기 |
| [BBC Health](bbc-health.md) `bbc-health` | 나쁨 | 73% | 사진이 있는 기사에서 Readability 가 뒤쪽 덩어리만 골라 앞 7문단·사진 4장이 빠짐. 영상 페이지는 BBC 바닥글(링크 목록·Copyright)이 본문으로 나옴. | BBC data-component 블록 모으기 · /videos/ 바닥글 거르기 |
| [BBC Sport](bbc-sport.md) `bbc-sport` | 부분 | 100% | 글은 98% 맞으나 사진이 다 빠짐. 영상 페이지 둘은 소개 글만(사이트도 그 정도) — 한국에서는 영상이 "이 지역에서 볼 수 없음". | BBC image-block 사진 살리기 |
| [BBC World](bbc-world.md) `bbc-world` | 나쁨 | 100% (최저 47%) | 사진이 낀 기사에서 앞 11문단·사진 3장이 빠짐(47%). 사진은 3건 모두 하나도 안 옴. | BBC data-component 블록 모으기 |
| [CNBC](cnbc.md) `cnbc` | 부분 | 100% | 글은 94~110% 맞음. 머리 사진은 빠지고 그 사진의 설명·출처 2줄이 첫 두 문단으로 들어옴(2/3). | 머리 사진 설명·출처 줄을 cap 으로(또는 빼기) |
| [Google AI](google-ai.md) `google-ai` | 부분 | 100% (최저 67%) | 보통 글은 맞지만, 큰 발표 글은 캐러셀 속 고객 인용 12개·영상 카드 설명 10개를 놓쳐 68%. 다른 글은 오디오 플레이어 문구·글쓴이 직함·AI 생성 고지·뉴스레터 신청이 섞임. | 플레이어·AI 고지·뉴스레터 문구 빼기 · 캐러셀 인용 살리기 |
| [Guardian Environment](guardian-env.md) `guardian-env` | 부분 | 100% | 글 기사·사진 모음은 맞음(사진 20장·설명 19 그대로). 영상 페이지는 짧은 소개 뒤에 "More on this story" 관련 기사 10줄이 본문으로 섞임. | "More on this story"·"Explore more on these topics" 뒤 자르기 |
| [MIT Technology Review](mit-tr.md) `mit-tr` | 좋음 | 100% | 3건 모두 100~102%. 부제·날짜·삽화 출처·뉴스레터 권유 몇 줄만 섞임. 피드가 전문을 줌. | 부제·날짜·뉴스레터 줄 빼기, paywall=metered |
| [NYT Politics](nyt-politics.md) `nyt-politics` | 나쁨 | - | 3건 모두 차단 403(앱 대조 포함). | 그대로 |
| [Quanta Magazine](quanta.md) `quanta` | 좋음 | 100% (최저 96%) | 3건 99~101%, 사진·설명 맞음. 부제 1줄은 모두, 한 기사는 끝에 뉴스레터·"Also in Physics"·"Comment on this article" 가 섞임. | 끝 뉴스레터·관련·댓글 머리 자르기 |
| [The Verge](verge-all.md) `verge-all` | 부분 | 100% | 본문은 다 오지만(사이트 대비 125~141% — 넘는 만큼이 군더더기) 3건 모두 기자 소개·"Follow topics and authors…"가 섞이고, 한 건은 페이지 머리(건너뛰기 링크·부제 2번·바이라인·날짜)까지 본문으로. | 기자 소개·팔로우 권유 빼기, paywall=metered |
| [AWS Machine Learning](aws-ml.md) `aws-ml` | 부분 | 100% | 글·목록·코드·소제목은 100% 가깝게 맞음. 다만 표(<table>)는 통째로 버려 표가 있는 기사에서 5개가 사라짐. | 표를 행 단위 글로 살리기 |
| [DW News](dw.md) `dw` | 부분 | 100% (최저 97%) | 일반 기사 2건은 글·사진·설명 모두 맞고 영상 자리 대체 문구 한 줄("To view this video please enable JavaScript…")만 섞임. 라이브 페이지는 시각 줄 13개가 문단으로 들어오고 맨 위 요약 목록이 빠짐. | 영상 대체 문구 빼기 · 라이브는 시각을 소제목으로 |
| [Guardian Business](guardian-business.md) `guardian-business` | 좋음 | 100% | 3건 모두 99~100%, 사진·설명 짝 맞음, 섞임 없음. | 없음 |
| [Hugging Face](huggingface.md) `huggingface` | 부분 | 100% | 글·목록·코드는 맞으나 벤치마크·비용 표가 빠짐(2/3). 피드에 요약이 아예 없음. | 표 살리기 |
| [MarketWatch](marketwatch.md) `marketwatch` | 나쁨 | - | 3건 모두 차단(401, captcha-delivery). 사이트도 헤드리스로는 확인 문제만 보임. 피드 요약도 짧아(25~130자) 읽기 창이 거의 빈 화면. | paywall 을 hard(또는 차단)로, 느린 길 건너뛰기 |
| [New Scientist](newscientist.md) `newscientist` | 좋음 | 100% (최저 97%) | 앱(URLSession)은 빠른 길로 전문(100~114%)을 얻음. 사진 모음 15장·설명 맞음. 다만 사진 설명 끝에 사진가 이름이 띄어쓰기 없이 붙음. | 설명 끝 사진가 이름 떼기 |
| [NPR World](npr-world.md) `npr-world` | 부분 | 100% | 글은 101~109% 맞음. 오디오 끼워넣기 코드(`Embed <iframe src=…>`)가 목록 줄로, 사진 출처가 따로 문단으로 섞임. | Embed 코드 줄·사진 출처 줄 빼기 |
| [NYT Business](nyt-business.md) `nyt-business` | 나쁨 | - | 빠른 길 403. 같은 날 여러 번 받은 뒤로는 앱도 헤드리스도 DataDome 확인 문제(403)로 차단(첫 점검의 NYT 다른 출처는 느린 길 1.5초에 열렸음). | 그대로(READSWEEP 처리 유지) |
| [The New York Times](nyt-home.md) `nyt-home` | 나쁨 | - | 첫 점검: 빠른 길 403 → 느린 길 1.5초 성공(블록 21~25개). 다시 잴 때와 앱 대조에서는 3건 모두 차단 403. | 그대로 |
| [Politico](politico.md) `politico` | 부분 | 88% | 뉴스레터(Playbook)는 100%. 일반 기사는 사이트·앱 모두 앞 4문단만 보이는데 **피드 content:encoded 에는 전문(4,358자)이 있음**. 영상 페이지는 앱이 올바르게 실패 처리. | 피드 본문이 더 길면 피드 본문 쓰기 |
| [STAT](stat.md) `stat` | 부분 | 100% | 일반 기사는 사이트가 4문단 뒤 Piano 벽으로 감추지만 HTML 에 전문이 있어 앱은 전문을 얻음. STAT+ 기사는 맛보기 + 구독 권유 7줄인데 길이가 1,500자를 넘어 유료벽 판정(looksBlocked)이 안 걸려 전문처럼 보임. | STAT+ 문구면 길이와 무관하게 유료 표시 |
| [TechCrunch](techcrunch-all.md) `techcrunch-all` | 부분 | 100% | 글은 103~119%(넘는 만큼이 군더더기). 3건 모두 제휴 고지, 2건은 기자 소개·연락처(“[email protected]” 꼴로 깨진 메일 주소)가 끝에 섞임. | 제휴 고지·기자 소개·연락처 줄 빼기 |
| [WIRED](wired-all.md) `wired-all` | 좋음 | 100% | 사이트는 첫 문단만 보여 주지만 HTML 에 전문이 있어 앱은 전문을 얻음(ld articleBody 대비 100~104%). 긴 기사는 머리의 날짜·제목·부제·삽화 출처가 본문으로 섞임. | 머리 날짜·제목·부제·삽화 출처 빼기 |

## 문제 종류별 출처 수

| 갈래 | 종류 | 출처 수 | 출처 |
|---|---|---|---|
| 잘림 | Readability 가 본문 여러 덩어리 중 하나만 고름 | 3 | ars-all, bbc-health, bbc-world |
| 잘림 | 표(<table>)를 통째로 버림 | 2 | aws-ml, huggingface |
| 잘림 | 캐러셀·영상 카드 속 글을 버림 | 1 | google-ai |
| 잘림 | 유료 맛보기만(앱이 유료로 못 알아봄) | 1 | stat |
| 잘림 | 사이트도 앞부분만 — 피드에는 전문 | 1 | politico |
| 사진 | 본문 사진이 빠짐(설명만 남기도) | 4 | bbc-health, bbc-sport, bbc-world, cnbc |
| 섞임 | 관련 글 목록 | 3 | anthropic, guardian-env, quanta |
| 섞임 | 기자 소개·연락처 | 4 | ars-all, google-ai, verge-all, techcrunch-all |
| 섞임 | 뉴스레터·구독 권유 | 4 | google-ai, mit-tr, quanta, stat |
| 섞임 | 플레이어·영상 대체 문구 | 2 | google-ai, dw |
| 섞임 | 사진 설명·출처가 문단으로 | 4 | ars-all, cnbc, newscientist, npr-world |
| 섞임 | 부제·요약문 중복 | 4 | mit-tr, quanta, verge-all, wired-all |
| 섞임 | 날짜·바이라인 줄 | 2 | dw, wired-all |
| 섞임 | 사이트 바닥글 | 1 | bbc-health |
| 섞임 | 제휴 고지 | 1 | techcrunch-all |
| 섞임 | 끼워넣기 코드(iframe) 글 | 1 | npr-world |
| 섞임 | 팔로우·알림 권유 | 1 | verge-all |
| 섞임 | 영상 페이지에서 본문 대신 군더더기 | 2 | bbc-health, guardian-env |
| 유료 표시 | paywall 값이 관찰과 다름 | 5 | mit-tr, verge-all, marketwatch, politico, stat |
| 차단 | 봇 막기로 앱에서 못 엶 | 4 | nyt-politics, marketwatch, nyt-business, nyt-home |

## 여러 출처에 걸친 규칙 제안(작업자 Reader 용)

앱 코드는 고치지 않았다. 효과가 큰 순서.

1. **본문이 여러 덩어리인 사이트는 덩어리를 모두 모으기**: BBC 3곳(`main article [data-component$="-block"]`)과 Ars(`article .post-content`). 지금은 Readability 가 한 덩어리만 골라 앞이나 뒤 절반이 빠진다(BBC World 47%, Ars 53~55%, BBC Health 72%). 출처별 본문 선택자 표(sources.json `bodySelector` 같은 칸)를 두고, 있으면 Readability 보다 먼저 쓰는 방식을 제안.
2. **표(<table>) 살리기**: 추출 스크립트 walk 에 table 이 없어 표 안 글이 블록이 되지 않고 통째로 사라진다(AWS 5개, Hugging Face 2개). 행마다 셀을 " · " 로 이어 li, 또는 pre 로.
3. **피드 본문이 더 길면 피드 본문 쓰기**: Politico 일반 기사는 사이트도 앱도 앞 4문단뿐인데 피드 content:encoded 에는 전문(3.5배)이 있다. 피드가 전문을 주는 곳: AWS·MIT TR·Politico·New Scientist(일부)·Verge(짧은 글). 추린 본문 < 피드 본문의 70% 이면 피드 본문으로.
4. **군더더기 문구 목록(일반 규칙)** — 블록 글이 이것과 같거나 이것으로 시작하면 빼기:
   - 플레이어: "Listen to article", "[[duration]] minutes", "Your browser does not support the audio element.", "To view this video please enable JavaScript…", "Video Player is loading."
   - 권유: "Follow topics and authors from this story…", "Email (required)", "When you purchase through links in our articles…", "Sign up for our newsletters…", "Get the latest updates from …", "Already have an account? Log in", "Subscribe to the POLITICO Playbook family"
   - 코드·고지: "Embed <iframe …", "This content is generated by Google AI…", "Skip to main content"
   - 바닥글: "Accessibility Help", "Contact the BBC", "Advertise with us", "Copyright © …"
5. **이 소제목부터 뒤는 자르기**: "Related content"(Anthropic), "More on this story"·"Explore more on these topics"(Guardian), "The Quanta Newsletter"·"Also in …"·"Comment on this article"(Quanta).
6. **기자 소개 문단**: 본문 끝의 "… is a (senior) reporter/editor/writer at …", "… writes about …", "You can contact or verify outreach from …"(TechCrunch·Verge·Ars). 지금 BodyCleanup 의 영어 바이라인은 "By Name" 한 줄만 잡는다.
7. **사진 설명·출처 줄**: 이미지 없이 문단으로 들어온 "… | Getty Images"·"이름/Getty Images"·"Credit: …"·"Illustration: …"(CNBC·NPR·Ars·MIT TR·Wired)은 cap 으로 바꾸거나 빼기. New Scientist 는 설명 끝에 사진가 이름이 띄어쓰기 없이 붙는다.
8. **영상 페이지**: 본문 글이 바닥글·관련 기사뿐이면 성공으로 치지 않고 "글이 거의 없는 기사"(BBC `/videos/`, Guardian `/video/`). Politico 영상은 지금도 올바르게 실패.
9. **유료 판정(Paywall.looksBlocked)**: STAT+ 맛보기는 맛보기 + 구독 권유 7줄이 1,500자를 넘어 걸리지 않는다. "exclusive to … subscribers"·"to read the rest of this story subscribe" 같은 강한 문구는 길이와 무관하게.

## 유료 표시(sources.json `paywall`) 제안

| 출처 | 지금 | 관찰 | 제안 |
|---|---|---|---|
| marketwatch | metered | 앱에서 3/3 차단(401, DataDome) | hard 또는 "앱에서 열리지 않음" + 느린 길 건너뛰기 |
| mit-tr | 없음 | Piano 구독 팝업(본문은 HTML·피드에 다 있음) | metered |
| verge-all | 없음 | ld isAccessibleForFree=false 2/3, 구독 문구 | metered |
| politico | 없음 | 일반 기사는 사이트에서도 앞 4문단만(ld false) | metered(로그인으로 풀리는지 사용자 확인 필요) |
| stat | metered | 일반 기사는 metered, STAT+ 는 hard | metered 유지 + STAT+ 기사만 hard |
| newscientist·wired | metered | 맞음(사이트는 몇 문단 뒤 벽, 앱은 HTML 의 전문) | 그대로 |
| nyt-* | metered | 맞음 + 이 Mac 에서는 DataDome 차단 | 그대로 |

정책 결정 필요(사용자): Wired·STAT·New Scientist·MIT TR 은 **사이트가 감춘 본문을 앱이 HTML 에서 얻어 보여 준다**. 그대로 둘지, 유료 기사는 맛보기만 보일지.

## 번역(작업자 Translate 용, 한 줄씩)

번역은 돌리지 않았다(블록 단위 번역이라 문단 어긋남은 구조상 생기기 어렵다). 구조상 위험만 적는다.

- 표가 사라져 번역할 것도 없음(AWS·HF) — 표를 살리면 셀 단위 번역이 필요.
- 번역기에 들어가면 안 되는 조각: iframe 코드 글(NPR), "[email protected]"(TechCrunch), "[[duration]] minutes"(Google AI).
- 같은 문장 두 번: Verge 한 건은 부제가 두 블록, Ars 는 사진 설명이 두 블록 — 같은 번역이 두 번 나옴.
- 설명과 사진가 이름이 붙은 글(New Scientist "…a visitor이름" 꼴) — 이름이 번역문 속에 섞일 수 있음.
- DW 라이브의 시각 줄("October 14, 2026")이 문단으로 들어와 날짜가 번역됨.

## 재는 법(다시 돌리기)

- 도구: `mac/sources-audit/tools/intl1/`(Node + Playwright 1.62.1, 헤드리스 WebKit·Chromium — 창 없음, 포커스 안 뺏음). `npm install` 뒤 `node audit.mjs [출처id…]` → 저장소 밖 `../srcaudit-shots/intl1/data/<id>.json`(기사 본문이 들어 있어 커밋하지 않음), 스크린샷 `../srcaudit-shots/intl1/<id>-<n>.png`. `node gen.mjs` 가 이 md 들을 만듦. `inspect.mjs` 는 터미널에서 블록을 비교해 보는 도우미.
- 앱 추출 재현(`appextract.mjs`): 앱 소스(`ArticleExtractor.swift` 의 추출 스크립트, `Resources/Readability.js`)를 그때그때 읽어 그대로 돌린다. 빠른 길(스크립트 끔·자원 막음) → 실린 본문 자료(EmbeddedArticle 포트) → 글 많은 페이지는 느린 길 건너뜀 → 느린 길(0.6초 뒤 0.4초마다, 15초/거절 6초) → 다듬기(BodyCleanup·잡그림·표지와 같은 첫 사진·Paywall.looksBlocked 포트).
- 앱 대조: 같은 기사 목록을 `DROPCAP_TEST_READSWEEP_REPLAY` 로 실제 앱에 넣어 얻은 길·초·글자·표지를 받음(READSWEEP.md 방법, 임시 DROPCAP_DATA_DIR).
- 사이트 표시: Chromium(데스크톱 Chrome UA, 1280×900)로 열어 2.5초 뒤 한 번, 천천히 끝까지 내린 뒤 한 번 재고(유료벽이 나중에 자르면 처음 것을 전문으로), 출처별 본문 선택자(여러 덩어리면 모두, 무한 스크롤로 붙은 다음 기사는 뺌), 링크 카드·관련 글 머리 뒤·nav/aside/광고·구독 상자는 본문 밖으로. 봇 막기에 걸리면 WebKit(Safari UA)로 한 번 더.
- 비교: 글자 수는 문단·소제목·목록·인용(사진 설명 제외). 빠진 것/섞인 것은 문장 앞 60자·끝 50자 일치로 찾고, md 에는 종류·개수·위치만 적음.
- 요청: 출처마다 기사 3건, 요청 사이 1.2~2초, 동시 3출처. 측정기를 고치느라 같은 기사를 4번 남짓 받았다 — NYT 는 그 사이 이 Mac 에 확인 문제를 내기 시작함(READSWEEP 때와 같은 현상).

## 한계

- 헤드리스·한국 IP 기준. 쿠키 동의 창(OneTrust·Sourcepoint)은 한국에서는 일부만 뜨고, BBC 영상은 지역 제한.
- 유료벽은 새 방문자(쿠키 없음) 기준 — 구독자·로그인 상태는 보지 못함.
- 피드 사진 크기는 피드에 적힌 width(없으면 ?)와 앱 대조의 표지 실제 크기.
- 기사 선택이 피드 날짜에 따라 정해져 Google AI·Hugging Face·Quanta 는 며칠 지난 글이 섞임(피드가 자주 안 올라옴).
