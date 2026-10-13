# 경쟁 앱 분석 — 일반 뉴스 '매거진' 전환을 위해

조사일 2026-10-13. 대상은 RSS·읽기 앱(Feedly, Inoreader, Reeder, NetNewsWire, Readwise Reader, Matter, Omnivore), 뉴스 큐레이션 앱(Apple News, Google News, SmartNews, Ground News, Particle, Artifact→Yahoo News, Perplexity Discover), 국내 서비스(네이버·다음 뉴스, 뉴닉, 어피티, 롱블랙, 폴인, 퍼블리), 알림 중심 앱(NYT·BBC 등 매체 앱, Breaking News, Robinhood·토스증권·키움)이다.

- 주장마다 출처 링크를 달았다. Reddit은 검색 도구가 막혀 있어 HN·MacPowerUsers·App Store 리뷰·보도로 대신했다.
- "2차"는 리뷰 블로그 같은 약한 출처라 방향 참고로만 쓴다.
- Dropcap의 현재 기능은 [`docs/FEATURES.md`](../FEATURES.md) 번호(C-·N-·M-…)로 가리킨다.
- RSS 주소 검증 원자료는 [`feeds.json`](feeds.json)에 있다. 145개를 확인했고 138개가 살아 있다.

---

## 요약

1. **Dropcap의 핵심 셋은 경쟁 앱들이 비워 둔 자리다.** 셋은 맥에 상주하는 실시간 알림, 기기 안 한국어 번역·요약, 같은 소식 묶기다.
   - 맥 메뉴바 RSS 알림 앱은 대부분 방치됐다([softpedia](https://mac.softpedia.com/get/Internet-Utilities/RSS-Bot.shtml), [rosettacheck](https://rosettacheck.com/apps/com.rockysandstudio.RSS-Notifier)).
   - NetNewsWire 알림은 늦게 오고([도움말](https://netnewswire.com/help/ios/5.0/en/notifications)), Inoreader 푸시는 유료다([가격](https://inoreader.com/pricing)).
   - Feedly는 중복 제거는 기본으로 주지만 키워드 뮤트는 월 $15.99인 Pro+에만 준다([뮤트](https://docs.feedly.com/article/109-how-can-i-add-create-a-mute-filter), [중복](https://docs.feedly.com/article/218-how-does-deduplication-work)).
   - Apple News는 한국에서 쓸 수 없다([2차](https://www.imore.com/how-get-apple-news-uk-australia-canada-and-more)). Particle·Ground News는 영어권 중심이다.
2. **일반 뉴스로 넓히면 가장 큰 위험은 알림 과잉이다.**
   - 국내 통신사·종합지 피드는 분야 하나에서 하루 수십~수백 건이 나온다(검증: 연합뉴스 사회 피드는 120건이 약 3시간 범위에 담김).
   - 지금 규칙(K-03: 하루 15건 넘는 채널은 알림 기본 끔)을 그대로 쓰면 국내 언론 출처가 거의 다 꺼진다. 알림 단위를 '출처'에서 '분야 + 중요도'로 옮겨야 한다.
   - 근거: 뉴스 알림을 받지 않는 사람의 43%는 직접 끈 사람이고, 이유 1위는 "너무 많다"(19%)다([Press Gazette, DNR 2025](https://pressgazette.co.uk/publishers/digital-journalism/mobile-news-alerts-push-notifications-digital-news-report-2025/)).
3. **국내 언론 RSS 약관은 거의 다 '개인·비상업적 이용만'을 허용하고, 몇 곳은 'AI 학습·활용 금지'를 걸었다.** 기본 출처 배포와 읽기 창 전문 표시·번역의 범위는 사용자 결정이 필요하다([(다)-4](#다-4-저작권약관--결정-필요)).

---

## (가) 기본인데 Dropcap에 없는 기능

"기본"은 조사한 앱 가운데 3곳 이상이 무료나 기본 등급으로 주는 기능, 또는 리뷰에서 반복해서 요구되는 기능이다. 맥 구현 위치는 `mac/Sources/Dropcap/` 기준이다.

| # | 무엇 | 어느 앱들이 기본으로 갖나 | 없을 때 불편 | 난이도 | 맥 구현 위치(대략) |
|---|---|---|---|---|---|
| G-1 | **첫 실행 관심 분야 고르기(온보딩)** + 분야별 추천 출처 묶음 | Google News 주제 팔로우([9to5google](https://9to5google.com/2022/09/22/how-to-customize-your-news-feed-in-google-news-and-google-discover/)), 다음 '구독 도우미'(관심 주제 → 언론사 추천, [카카오](https://www.kakaocorp.com/page/detail/10805)), Yahoo News(옛 Artifact) 주제·매체 선택([TheWrap](https://thewrap.com/yahoo-news-artifact-app-ai-technology)), Perplexity Discover 카테고리([2차](https://www.firstaimovers.com/p/perplexity-discover-feed)) | 일반 뉴스에서는 기본 출처를 다 켜면 첫날부터 홍수가 난다. 무엇을 받을지 고를 길이 없다 | 중 | 새 `UI/OnboardingView.swift`, `AppModel`(첫 실행 분기, M-12 첫 호), `shared/sources.json`에 `category` 필드 추가, `Core/Category.swift` |
| G-2 | **분야별 알림 켜고 끄기** | Apple News 채널별 알림([Apple](https://support.apple.com/guide/news/iph82f485965/mac)), NYT 주제별 알림 체크박스([NYT 도움말](https://thenewyorktimeshelpcenter.helpjuice.com/115003859548-The-New-York-Times-News-App/115015970768-Android-News-App)), AP 관심사 알림([App Store](https://apps.apple.com/us/app/ap-news/id364677107)) | 경제는 바로 받고 스포츠는 매거진에서만 보는 식의 구분을 할 수 없다. 지금은 출처 단위(종 단추, P-06)뿐이다 | 하 | `AppModel.checkAll`(C-25 분기 옆), `Store`에 `notifyCategories`, `SettingsView`(새 '분야' 탭) |
| G-3 | **출처·주제 차단이 묶음 안에서도 예외 없이 적용됨** + 카드에서 바로 "이 출처 숨기기 / 이런 소식 줄이기" | Google News "Hide all stories from…"·"Fewer stories like this"([포럼](https://support.google.com/googlenews/thread/18239231/increasingly-horrible-feed?hl=en)), Yahoo News 키워드·매체 차단([Thurrott](https://www.thurrott.com/mobile/303955/artifact-lives-on-in-the-new-yahoo-news-app)), Reeder 키워드 필터([도움말](https://reederapp.com/help)) | Google과 Apple 모두 "숨겨도 묶음·상단에 다시 나온다"는 불만 1순위([Android Authority](https://androidauthority.com/google-news-features-wish-list-2026-3674121), [Chrome Unboxed](https://chromeunboxed.com/5-google-news-improvements-that-will-never-happen)). Dropcap은 설정 화면에 들어가야만 낱말이나 출처를 끈다 | 하 | `AppModel.applyKeywords`·`groupSameStory`(대표 선정 전 제외), `MenuView.Row`·`StoryCard`·`ToastView` 오른쪽 클릭 메뉴, `interestWeight`(줄이기 = 음의 가중치) |
| G-4 | **피드 날짜 관대 해석**(날짜 없음·시간대 오류·비표준 형식) | 경쟁 앱의 기능이라기보다 국내 피드를 쓰려면 꼭 있어야 하는 기본기다(경쟁 앱 쪽 근거 문서는 찾지 못함). 근거는 이번 검증 결과다(`feeds.json`의 `dateIssue`) | **한겨레**는 모든 피드에 글 날짜가 없다. **매일경제·코리아헤럴드**는 KST 시각을 +0000으로 찍어 최대 9시간 미래가 된다. **노컷뉴스**는 `Tue, 13 10 2026`처럼 월을 숫자로 쓴다. 그대로 두면 C-09(3일 규칙)·"몇 분 전"·정렬·M-05 호 엮기가 틀어진다 | 하 | `Core/FeedParser.swift`(날짜 파서), `AppModel.fresh`(미래 시각은 받은 시각으로 자름, 날짜 없으면 처음 본 시각) |
| G-5 | **출처 건강 표시**(갱신 멈춤·주소 죽음·형식 오류) | Inoreader 피드 상태, NetNewsWire 오류 표시(경쟁 앱 일반 기능) | 검증에서 JTBC 속보(2024-10 이후 멈춤)·NHK(2026-08 이후 멈춤)·뉴스1·디지털데일리(RSS 주소가 HTML을 돌려줌)·헬로디디(XML 오류)가 나왔다. 분야 출처가 조용히 죽으면 "그 분야는 소식이 없다"로 오해한다 | 하 | `FeedService.items`(마지막 성공 시각·마지막 새 글 시각 기록), `SettingsView.sources`(P-06의 오류 표시 확장) |
| G-6 | **OPML 가져오기·내보내기** | Inoreader(자동 OPML 백업, [가격](https://inoreader.com/pricing)), Readwise Reader([FAQ](https://docs.readwise.io/reader/docs/faqs/feed)), Reeder(유료, [도움말](https://reederapp.com/help)), NetNewsWire, Feedly | 다른 리더에서 옮겨 오거나 떠날 수 없다. Omnivore 종료 때 "2주 안에 내보내라" 사태가 불신을 남겼다([HN](https://news.ycombinator.com/item?id=41985118)) | 하 | `Core/Channels.swift`(`ChannelResolver`로 하나씩 확인), `SettingsView.sources` 단추 |
| G-7 | **목록·매거진 키보드 탐색**(J/K·M 읽음·S 저장·O 브라우저) | Feedly([단축키](https://docs.feedly.com/article/81-what-are-the-keyboard-shortcuts)), Reeder(J/K·L/B/F), Readwise(커맨드 팔레트, [문서](https://docs.readwise.io/reader/docs/faqs/navigation)) | Matter에는 단축키가 없다는 불만이 리뷰에 있다([App Store](https://apps.apple.com/us/app/matter-read-listen-learn/id1501592184)). Dropcap은 ⌘1~4·⌘F·⌘R만 있다(M-20) | 하 | `MenuView`(선택 행 상태), `MagazineView`(포커스된 카드), `ReaderView`(J/K로 다음 기사) |
| G-8 | **아무 웹 주소나 '나중에 읽기'로 보내기**(공유 메뉴·브라우저에서) | Readwise·Matter·Reeder Share extension, Readwise 저장 메일 주소([문서](https://docs.readwise.io/reader/docs/faqs/email-newsletters)) | 피드에 없는 기사를 저장하거나 스크랩할 수 없다. 스크랩북·지식 물병이 피드 안에 갇힌다 | 중 | 새 Share Extension 타깃(또는 `dropcap://save?url=` URL 스킴 + 서비스 메뉴), `AppModel.toggleSaved`, `ArticleService` |
| G-9 | **스크랩·하이라이트를 노트 앱으로 바로 보내기**(Obsidian 폴더 자동 저장) | Readwise·Matter의 Notion/Obsidian 내보내기([Readwise](https://readwise.io/pricing), [Matter](https://www.getmatter.com/updates/sync-to-obsidian)) | 지금은 Markdown 복사·파일 저장을 손으로 한다(M-18) | 하 | `Core/Scrapbook.swift`(폴더를 정해 두고 스크랩 때마다 `.md` 갱신), `SettingsView` |
| G-10 | **읽기 창 모양 고르기**(줄 간격·폭·세피아/어둡게)·**기사 안 찾기(⌘F)** | 롱블랙·뉴닉·폴인 리뷰에 다크모드·행간 요청이 반복된다([뉴닉 리뷰](https://itunes.apple.com/kr/rss/customerreviews/page=1/id=1549450444/sortby=mostrecent/json), [롱블랙 리뷰](https://itunes.apple.com/kr/rss/customerreviews/page=1/id=6450910866/sortby=mostrecent/json)). Reeder·Readwise는 레이아웃 옵션을 기본으로 준다 | 지금은 글자 크기만 바꿀 수 있다(R-06). 긴 해설 기사를 읽을 때 불편하다 | 하 | `Reader/ReaderView.swift`(설정 값은 `fs`처럼 기억) |
| G-11 | **유료 기사 미리 표시** | Apple News+ 표시(그래도 "눌러 봐야 안다"는 불만), 저평점 리뷰 주제 1위가 유료벽 21%([2차](https://unstar.app/blog/apple-news-google-news-flipboard-reddit-news-apps-ranked-2026)) | 눌렀는데 읽기 창이 "본문을 추리지 못했습니다(유료 기사·차단 등)"로 끝난다(ReaderView 실패 화면) | 중 | `shared/sources.json`에 `paywall: hard/metered`, 추출 실패 기록을 `Database`에 쌓아 출처별 실패율 계산, `StoryCard`·`MenuView.Row`에 자물쇠 표시 |
| G-12 | **기기 간 이어 읽기**(아이폰 앱 또는 iCloud 동기화) | Feedly·Inoreader·NetNewsWire(iCloud), Reeder(iCloud, [도움말](https://reederapp.com/help)) | 맥에서 저장한 기사를 출퇴근길에 못 읽는다. 다만 NetNewsWire iCloud 동기화도 대용량에서 느리다는 평이 있다([iMore](https://www.imore.com/netnewswire-6-adds-icloud-rss-syncing-twitter-and-reddit-integration-and-more)) | 상 | 저장·스크랩·읽음만 CloudKit 비공개 DB로(`Store`·`Database`). 세 운영체제 공통 목록이라 윈·리에서는 ⊘ 후보 |
| G-13 | **위젯·단축어(Shortcuts)·Spotlight** | NetNewsWire 위젯 3종([9to5mac](https://9to5mac.com/2021/06/22/netnewswire-icloud-sync-more-iphone-ipad-update/)), Matter 위젯, 폴인 리뷰에서 위젯 요청 | 메뉴바를 열지 않고 오늘의 표지나 안 읽은 수를 보는 길이 없다 | 중 | WidgetKit 확장 타깃 + App Intents(`AppModel` 읽기 전용 스냅샷을 App Group에 저장) |
| G-14 | **뉴스레터 받기(전용 메일 주소)** | Feedly·Inoreader(Pro)·Readwise([Feedly](https://docs.feedly.com/article/663-how-to-follow-a-newsletter)) | 뉴닉·어피티 같은 국내 뉴스레터는 RSS가 없어서 들일 수 없다 | 상 | 서버가 필요하다(Dropcap은 서버가 없음). 대안: Gmail/IMAP 라벨 읽기(`FeedService` 옆 새 `MailSource`), 또는 Substack·maily.so의 RSS만 받기(K-02 확장) |

> 이미 있어서 표에서 뺀 것: 안 읽음 수·읽음 표시(새 Reeder는 이걸 빼서 반발을 샀다 — [MPU](https://talk.macpowerusers.com/t/trying-the-new-reeder-app/38341?page=2)), 전체 기록 검색, 오프라인 나중에 읽기, 소리 내어 읽기, 같은 소식 묶기, 키워드 거르기, 방해 금지 시간.

---

## (나) 차별화 기능 후보 (14개)

정체성 표기: 💧물방울·실시간 알림 / 🌐기기 안 번역·요약 / ✂︎스크랩 / 🫙지식 물병 / 🧵같은 소식 묶기·스토리.

| # | 한 줄 개념 | 왜 차별화인가(근거) | 정체성 연결 | 난이도 | 위험 |
|---|---|---|---|---|---|
| D-1 | **중요도 문턱 알림**: 분야마다 "N곳 이상 보도한 소식만 물방울"(기본 국내 3곳)로 정한다. 공식 발표·★ 낱말은 예외로 바로 알린다 | 증권 앱의 변동률 문턱(5%/10%, [Robinhood](https://robinhood.com/us/en/support/articles/price-alerts/))을 뉴스로 옮긴 것이다. 매체 앱은 편집국이 손으로 고른다(NYT 속보/주요 분리, [Nieman](https://www.niemanlab.org/2016/07/the-new-york-times-is-giving-readers-more-control-over-email-and-mobile-push-alerts/)). 포털에는 분야·키워드 단위 알림 설정이 확인되지 않는다(네이버 이슈 NOW 업데이트에도 알림 언급 없음, [파이낸셜뉴스](https://www.fnnews.com/news/202502101742235107)) | 💧🧵 이미 있는 "외 N곳"(C-15)을 그대로 문턱으로 쓴다 | 하 | 첫 보도가 늦게 알려진다. 문턱에 닿는 순간 알리고 "처음 보도 n분 전"을 함께 표시해 보완한다 |
| D-2 | **물이 고이는 묶음 알림**: 분야별 하루 상한(기본 3)을 넘거나 '묶음' 모드인 분야의 소식은 상단바 아이콘에 물로 고인다. 정한 시각에 **한 방울**("경제 7건")로 떨어진다 | 하루 상한 사례: The Times 4건, BBC 약 10건, FT 아침+오후 5시 개인화 1건([Press Gazette](https://pressgazette.co.uk/publishers/digital-journalism/mobile-news-alerts-push-notifications-digital-news-report-2025/)). Newman은 알림을 "무딘 도구"로 쓰지 말라고 권한다(같은 기사). 키움 장 마감 AI 시황 알림은 3개월 만에 26만 명이 신청했다([스마트투데이](https://www.smarttoday.co.kr/ko-kr/articles/68623)) | 💧 물방울 은유를 그대로 확장한다(물이 고였다 떨어진다). C-21 아침 브리핑을 분야별로 일반화한 것이다 | 중 | 없음(기기 안). 상한이 너무 낮으면 큰 소식을 놓친다 → D-1 문턱을 넘은 소식은 상한과 무관하게 알린다 |
| D-3 | **해외·국내 같은 이야기 나란히**: 묶음 안에서 해외 보도(한국어 번역 제목)와 국내 보도를 두 줄로 보여 준다. "해외에서는 이렇게, 국내에서는 이렇게" | 포털은 국내 언론만 묶는다(네이버 클러스터링, [기자협회보](https://www.journalist.or.kr/m/m_article.html?no=35747)). Particle·Ground는 영어권 안의 좌우 비교다([TechCrunch](https://techcrunch.com/2024/11/12/particle-launches-an-ai-news-app-to-help-publishers-instead-of-just-stealing-their-work)). DNR 2025에서 AI 번역 관심은 24%로 2위다([Reuters Institute](https://reutersinstitute.politics.ox.ac.uk/digital-news-report/2025/dnr-executive-summary)) | 🌐🧵 T-04(titleEn)와 StoryMatch 문장 임베딩이 이미 언어를 넘어 묶는다 | 중 | 번역 오류. 원제목을 함께 보여 주는 지금 방식(R-05)을 유지한다 |
| D-4 | **보도 지도(편향 라벨 없이)**: 스토리마다 누가 언제 처음 보도했는지, 국내/해외·통신/종합/경제지 분포, 아직 다루지 않은 주요 매체를 보여 준다 | Ground News Blindspot은 칭찬받지만 좌우 라벨이 주관적이라는 비판이 있다([2차](https://app.stationx.net/articles/ground-news-review)). 한국 매체는 편향 등급 자료도 없다. 뉴닉 1점 리뷰의 다수가 '정치 편향'이다([리뷰](https://itunes.apple.com/kr/rss/customerreviews/page=1/id=1549450444/sortby=mostrecent/json)) | 🧵 M-14 스토리 타임라인을 확장한다 | 중 | 공정성 시비. 순위를 매기지 않고 사실(시각·매체 유형)만 보여 준다 |
| D-5 | **이야기 따라가기**: 스토리나 카드에서 "이 이야기 계속 알려 줘"를 누르면 새 보도가 붙을 때마다 작은 물방울이 온다(기본 7일 뒤 자동 해제) | 네이버 '이슈 NOW' 구독에는 알림이 없다(위 파이낸셜뉴스). 증권 앱은 '내 관심 종목의 왜'를 알림으로 보내는 쪽으로 가고 있다(토스 AI 시그널, [헤럴드](https://www.heraldk.com/article/2025111117325540433)) | 💧🧵 클러스터 id를 구독한다 | 하 | 없음 |
| D-6 | **관심 낱말 워치리스트**: 회사·인물·법안 같은 낱말을 관심 종목처럼 등록한다. 묶음당 한 번만 알리고 하루 한 번 "오늘 ○○ 소식 3건" 요약을 보낸다 | Feedly 키워드 추적은 Pro, 뮤트는 Pro+ 월 $15.99다([App Store](https://apps.apple.com/us/app/feedly-smart-news-reader/id396069556)). Google News에는 키워드 뮤트가 없다(Android Authority) | 💧 C-14 꼭 알림을 '목록 + 하루 요약'으로 키운다. 🌐 요약은 기기 안 | 하 | 없음 |
| D-7 | **사실형 제목 보기(기기 안)**: 낚시성 제목이면 기기 안 모델이 사실 중심 제목을 만들어 원제목 아래 작게 보여 준다. 표시를 붙이고 끌 수 있다 | Artifact의 "킬러 기능"이었다([Six Colors](https://sixcolors.com/post/2024/01/artifacts-killer-feature-was-rewriting-bad-headlines/)). Yahoo News가 그대로 가져갔다 | 🌐 T-06 요약과 같은 기기 안 모델 | 중 | **높음**. Apple Intelligence 알림 요약이 오보를 내 2025년 1월 중단됐다([silicon republic](https://www.siliconrepublic.com/business/apple-halt-ai-notification-summaries-backlash-features)). 한겨레 피드에는 "AI 활용 금지"가 적혀 있다. **알림에는 원제목만 쓰고, 읽기 창 안에서 표시를 붙여 보조로만** 둔다 |
| D-8 | **회의·발표 중 자동 조용히**: 캘린더 일정 중이거나, 화면을 공유하거나, 전체 화면이면 물방울 대신 고이게(D-2) 한다 | 윈도우 쪽은 이미 N-23 계획에 있다. 매체 앱·포털은 모두 모바일이라 이런 '책상 위 맥락'을 모른다. 알림을 끈 이유로 "양과 타이밍"이 30%였다([Nieman 2016](https://www.niemanlab.org/2016/10/study-push-alerts-encourage-news-app-users-to-actually-open-the-app/)) | 💧 | 중 | 캘린더 권한(EventKit)이 필요하다. 끄기 쉽게 둔다 |
| D-9 | **유료 기사면 같은 이야기의 무료 보도로 안내**: 유료로 막힌 기사에서 묶음 안의 열리는 기사를 먼저 보여 준다 | 유료벽은 저평점 리뷰 주제 1위(21%)다([2차](https://unstar.app/blog/apple-news-google-news-flipboard-reddit-news-apps-ranked-2026)). 묶음 데이터가 있는 앱만 할 수 있다 | 🧵 G-11과 짝 | 하 | 매체 반발 가능성. 원문 링크는 항상 남긴다 |
| D-10 | **분야별 물빛의 지식 물병 + 편식 알림**: 분야마다 물 색을 다르게 하고, 한 분야만 쌓이면 "이번 주 과학 물이 말랐어요" 같은 부드러운 권유를 한다. 벌칙은 두지 않는다 | 뉴닉은 스트릭과 꾸미기로 습관을 만들지만 스트릭 초기화에 불만이 나온다. 롱블랙의 24시간 제약은 방문을 늘렸지만(주 4회 이상 60%) "놓치면 돈 내라"는 반감을 샀다([기자협회보](https://www.journalist.or.kr/m/m_article.html?no=54421), [리뷰](https://itunes.apple.com/kr/rss/customerreviews/page=1/id=6450910866/sortby=mostrecent/json)) | 🫙 `Knowledge.Drop.category`가 이미 저장된다 | 하 | 없음. 지금처럼 '쌓이는' 구조를 지킨다 |
| D-11 | **오늘 다 마셨어요(끝이 있는 매거진)**: 오늘 호의 대표 기사를 다 읽으면 "오늘 호 완독"을 표시하고 더 밀어 넣지 않는다 | 새 Reeder의 "always on firehose"는 반발을 샀다([MPU](https://talk.macpowerusers.com/t/trying-the-new-reeder-app/38341?page=2)). 뉴스 회피 40~42%의 이유 2위는 "뉴스 양에 지침"(31%)이다([Statista](https://www.statista.com/chart/34635/why-people-actively-try-to-avoid-the-news), [DNR 2026](https://reutersinstitute.politics.ox.ac.uk/digital-news-report/2026/dnr-executive-summary)) | 🫙 M-04 호 엮기 + 물병 | 하 | 없음 |
| D-12 | **스크랩 → 노트 자동 흐름 + 주간 스크랩 호**: 스크랩이 Obsidian 폴더에 바로 쌓이고, 주말에 "이번 주 내가 모은 문장"이 매거진 호로 엮인다 | Readwise는 연 $119.88 번들로만 판다([가격](https://readwise.io/pricing)). 국내 뉴스 서비스에는 문단 스크랩이 없다 | ✂︎🫙 M-17·M-18 | 하 | 없음(기기 안) |
| D-13 | **장 마감·저녁 정리 브리핑(분야별)**: 경제는 장 마감 직후, 나머지는 저녁에 "오늘 이 분야에서 무슨 일이 왜"를 기기 안에서 3줄로 요약해 보낸다 | 키움 AI 시황 26만 명(위 링크), 토스 '실시간 이슈' Top 20([헤럴드](https://www.heraldk.com/article/2026032416194438288)), 어피티 115만·뉴닉 150만 = '쉬운 경제·시사' 수요([어피티](https://uppity.co.kr/), [flex](https://flex.team/blog/2025/04/16/newneek)) | 🌐💧 C-21 확장 | 중 | 요약 오류(D-7과 같은 원칙). 요약 아래에 근거 기사 링크를 단다 |
| D-14 | **계정 없음·서버 없음을 약속으로**: 읽은 기록·관심사·요약이 모두 기기 안에 있다는 점을 설정과 소개에 분명히 적고, 언제든 전부 내보낼 수 있게 한다 | Omnivore는 2주 안에 내보내라고 공지했고([HN](https://news.ycombinator.com/item?id=41985118)) Pocket도 종료했다. Feedly는 기업용으로 옮겨 가며 개인 사용자를 방치했다는 평을 받는다([TechCrunch 2026-08](https://techcrunch.com/2026/08/17/feedly-attributes-weeklong-slowdown-to-bug-not-its-ai-pivot)). 가격 인상 불신(Inoreader [AlternativeTo](https://alternativeto.net/software/inoreader/about), Reeder $1→$1.99) | 🫙✂︎ 전부 | 하 | G-12(기기 간 동기화)와 긴장 관계다. 동기화는 iCloud 비공개 DB로만 한다 |

> **피해야 할 것**(근거 있는 실패)
> - 댓글·공유 같은 소셜 기능: Artifact는 8명 팀으로 모더레이션을 감당하지 못했다([DT Next](https://www.dtnext.in/lifestyle/technology/instagram-co-founders-shut-down-their-artifact-news-app-760883)). Yahoo News 최대 불만도 댓글 독성이다.
> - 기능을 계속 덧붙여 정체성이 흐려지는 것: Artifact 종료의 공식 사유는 "market opportunity isn't big enough"였다([TechCrunch](https://techcrunch.com/2024/01/12/instagram-co-founders-news-aggregation-startup-artifact-to-shut-down)).
> - 광고에만 기대는 속보 앱: NBC Breaking News는 팔로워 900만이 넘었는데도 2016년에 문을 닫았다([Nieman](https://niemanlab.org/2016/12/when-10-million-followers-isnt-enough-nbc-news-will-shut-down-the-breaking-news-app-on-dec-31)).
> - 알림을 앱 실행 유도용으로 쓰는 것: SmartNews 사례([Nieman](https://www.niemanlab.org/reading/news-aggregator-app-smartnews-latest-feature-aims-to-tackle-doomscrolling/)).
> - 한 번 더 누르게 만드는 단계 추가: 뉴닉 2026-08 '자세히 보기' 반발(위 리뷰).

---

## (다) 일반 뉴스 전환 때 꼭 정해야 할 것

### (다)-1 분야 체계

두 포털의 공통 분모는 **정치·경제·사회·생활/문화·세계·IT/과학** 6개다. 다음은 '기후/환경'을 따로 두고 IT/과학 아래 첫 칸에 'AI'를 둔다. 네이버 상위 섹션은 [news.naver.com](https://news.naver.com/), 다음은 [news.daum.net](https://news.daum.net/)·[IT/과학](https://news.daum.net/tech)에서 2026-10-13에 직접 확인했다.

**제안: 처음 고르는 분야 10개 + '주요 뉴스' 흐름 1개**

| id | 이름 | 포털 대응 | 메모 |
|---|---|---|---|
| `top` | 주요 뉴스 | 랭킹·헤드라인 | 분야가 아니라 흐름이다. 여러 분야에서 D-1 문턱을 넘은 소식만 모은다. 기본 켬 |
| `politics` | 정치 | 정치 | 북한 포함 |
| `economy` | 경제 | 경제 | 하위: 증권·부동산·산업. 알림 기본값을 '장 마감 묶음'(D-13)으로 할 후보 |
| `society` | 사회 | 사회 | 피드량이 가장 많다(연합 사회 ≈ 3시간에 120건) |
| `world` | 국제 | 세계/국제 | 해외 원문 비중이 가장 크다(D-3 효과가 큼) |
| `tech` | IT | IT/과학 | |
| `ai` | AI | 다음 IT/과학 > AI | **지금 Dropcap 전체가 여기로 들어간다.** 기존 하위 분류(보안·정책·투자·연구·모델, C-16)는 AI 안의 칩으로 남긴다 |
| `science` | 과학 | IT/과학 | 우주·의학연구 포함 |
| `life` | 생활·건강 | 생활/문화(건강) | 건강·의학·여행·음식 |
| `culture` | 문화·연예 | 생활/문화·엔터 | |
| `sports` | 스포츠 | 스포츠 | |
| (선택) `climate` | 기후·환경 | 다음 기후/환경 | 국내 전용 RSS를 찾지 못했다(한겨레 기후 주소 404). 처음엔 해외 출처만 있으므로 '더 보기'에 둔다 |

결정할 점:
- **분류 방법을 바꾼다.** 지금은 낱말 규칙으로 분류한다(C-16). 일반 뉴스에서는 **출처 피드의 분야를 1순위**로 쓴다. 국내 언론은 섹션별 피드를 주므로 거의 정확하다. '전체' 피드에서 온 글만 낱말 규칙으로 보충하고, AI는 지금처럼 `aiPattern`으로 다른 분야 글에서도 끌어온다.
- 한 기사가 여러 분야에 걸리면 하나만 대표로 정하고 칩은 여러 개 단다(네이버도 한 기사를 여러 섹션에 넣는다, [기자협회보](https://www.journalist.or.kr/ezview/article_main.html?no=47749)).
- 앱 문구 "AI 소식"(U-02, N-10 "AI 소식 N건 더", N-15 견본 문구, M-06 "AI 매거진")을 모두 바꿔야 한다.

### (다)-2 분야별 추천 출처 (직접 열어 확인함)

- 검증 방식: 2026-10-13 07:00 UTC 무렵 Safari UA로 내려받아 RSS·Atom·RDF로 해석했다. '살아 있음'은 글이 1개 이상이고 최근 글(또는 채널 갱신)이 14일 이내인 경우다.
- '하루 글 수'는 피드에 7일치 이상 담겼으면 실측이고, 아니면 피드 안 글들의 시간 범위로 외삽한 값이다.
  - 외삽 범위가 하루 미만이면 낮 시간대만 보고 늘린 값이라 과대 추정이다. 이런 값은 "≈수백"처럼 크기만 적었다.
- 원자료와 전체 145개는 [`feeds.json`](feeds.json)에 있다. 아래는 분야마다 고른 추천이고, ★는 기본으로 켤 후보다.

| 분야 | 국내(ko) — 이름 · 주소 · 하루 글 수 | 해외 — 이름 · 주소 · 언어 · 하루 글 수 |
|---|---|---|
| 주요 | ★연합뉴스 최신 `https://www.yna.co.kr/rss/news.xml` ≈수백~천 · SBS 주요 `https://news.sbs.co.kr/news/headlineRssFeed.do?plink=RSSREADER` ≈50 · 조선일보 `https://www.chosun.com/arc/outboundfeeds/rss/?outputType=xml` ≈25 · MBC 주요 `https://imnews.imbc.com/rss/google_news/narrativeNews.rss` ≈17 | ★BBC News `https://feeds.bbci.co.uk/news/rss.xml` en 4.4(실측) · NYT Home `https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml` en ≈5 · NPR `https://feeds.npr.org/1001/rss.xml` en ≈10 · Korea Herald `https://www.koreaherald.com/rss/newsAll` en ≈수백(시간대 오류) |
| 정치 | ★연합 정치 `https://www.yna.co.kr/rss/politics.xml` ≈150 · 경향 정치 `https://www.khan.co.kr/rss/rssdata/politic_news.xml` ≈40 · 동아 정치 `https://rss.donga.com/politics.xml` ≈50 · SBS 정치 `…SectionRssFeed.do?sectionId=01&plink=RSSREADER` ≈40 · 연합 북한 `https://www.yna.co.kr/rss/northkorea.xml` ≈14 | NYT Politics `https://rss.nytimes.com/services/xml/rss/nyt/Politics.xml` en ≈9 · Politico `https://rss.politico.com/politics-news.xml` en 2.1(실측) |
| 경제 | ★연합 마켓+ `https://www.yna.co.kr/rss/market.xml` ≈120 · ★한국경제 증권 `https://www.hankyung.com/feed/finance` ≈54 · 매일경제 증권 `https://www.mk.co.kr/rss/50200011/` ≈50(시간대 오류) · 서울경제 경제 `https://www.sedaily.com/rss/economy` ≈42 · 조선 경제 `https://www.chosun.com/arc/outboundfeeds/rss/category/economy/?outputType=xml` 13.9(실측) · 한경 부동산 `https://www.hankyung.com/feed/realestate` ≈10 | ★CNBC `https://www.cnbc.com/id/100003114/device/rss/rss.html` en ≈34 · WSJ Markets `https://feeds.content.dowjones.io/public/rss/RSSMarketsMain` en 7.6(실측) · MarketWatch `https://feeds.content.dowjones.io/public/rss/mw_topstories` en ≈40 · BBC Business `https://feeds.bbci.co.uk/news/business/rss.xml` en 4.0(실측) · FT `https://www.ft.com/rss/home` en ≈19(유료) · Economist `https://www.economist.com/finance-and-economics/rss.xml` en 0.9(유료) |
| 사회 | ★연합 사회 `https://www.yna.co.kr/rss/society.xml` ≈수백 · 경향 사회 `https://www.khan.co.kr/rss/rssdata/society_news.xml` ≈52 · 동아 사회 `https://rss.donga.com/national.xml` ≈200 · SBS 사회 `…sectionId=03…` ≈200 · 노컷 사회 `https://rss.nocutnews.co.kr/category/society.xml`(날짜 비표준) | — (국내 중심 분야) |
| 국제 | ★연합 국제 `https://www.yna.co.kr/rss/international.xml` ≈200 · 경향 국제 `https://www.khan.co.kr/rss/rssdata/kh_world.xml` ≈28 · 동아 국제 `https://rss.donga.com/international.xml` ≈49 · SBS 국제 `…sectionId=07…` ≈85 | ★BBC World `https://feeds.bbci.co.uk/news/world/rss.xml` en ≈21 · ★Guardian World `https://www.theguardian.com/world/rss` en ≈9 · NYT World `https://rss.nytimes.com/services/xml/rss/nyt/World.xml` en ≈14 · Al Jazeera `https://www.aljazeera.com/xml/rss/all.xml` en ≈60 · DW `https://rss.dw.com/rdf/rss-en-top` en ≈23 · NPR World `https://feeds.npr.org/1004/rss.xml` en ≈7 |
| IT | ★블로터 `https://www.bloter.net/rss/allArticle.xml` ≈50 · ★GeekNews `https://news.hada.io/rss/news` ≈45 · ZDNet Korea `https://zdnet.co.kr/feed/` ≈수백 · 전자신문 `https://rss.etnews.com/Section901.xml` ≈140 · 테크M `https://www.techm.kr/rss/allArticle.xml` ≈47 · 디일렉 `https://www.thelec.kr/rss/allArticle.xml` ≈28 · 바이라인네트워크 `https://byline.network/feed/` ≈3 | ★The Verge `https://www.theverge.com/rss/index.xml` en ≈2 · Ars Technica `https://feeds.arstechnica.com/arstechnica/index` en ≈6 · TechCrunch `https://techcrunch.com/feed/` en ≈16 · Wired `https://www.wired.com/feed/rss` en ≈13 · Hacker News `https://hnrss.org/frontpage` en ≈32 |
| AI | ★AI타임스 `https://www.aitimes.com/rss/allArticle.xml` ≈27 · 전자신문 AI `http://rss.etnews.com/04046.xml` | 기존 `shared/sources.json` 출처를 그대로 쓴다(OpenAI 1.9/일 실측, DeepMind, MIT Tech Review AI 0.6, The Verge AI ≈3) |
| 과학 | ★동아 과학 `https://rss.donga.com/science.xml` ≈42 · 전자신문 과학 `http://rss.etnews.com/20.xml` ≈42 · 경향 과학 `https://www.khan.co.kr/rss/rssdata/science_news.xml` 5.4(실측) · 한겨레 과학 `https://www.hani.co.kr/rss/science/`(날짜 없음) | ★Nature `https://www.nature.com/nature.rss` en ≈15 · ★Quanta `https://www.quantamagazine.org/feed/` en 0.4(실측) · ScienceDaily `https://www.sciencedaily.com/rss/all.xml` en ≈9 · New Scientist `https://www.newscientist.com/feed/home/` en ≈2 · NASA `https://www.nasa.gov/feed/` en ≈3 · BBC Science `https://feeds.bbci.co.uk/news/science_and_environment/rss.xml` en 3.7(실측) |
| 생활·건강 | ★연합 건강 `https://www.yna.co.kr/rss/health.xml` ≈23 · 동아 건강 `https://rss.donga.com/health.xml` ≈6 · 코메디닷컴 `https://kormedi.com/feed/` ≈100 · 전자신문 바이오 `http://rss.etnews.com/20042.xml` ≈25 | STAT `https://www.statnews.com/feed/` en ≈8 · NYT Health `https://rss.nytimes.com/services/xml/rss/nyt/Health.xml` en 2.0(실측) · BBC Health `https://feeds.bbci.co.uk/news/health/rss.xml` en 4.1(실측) |
| 문화·연예 | ★연합 문화 `https://www.yna.co.kr/rss/culture.xml` ≈145 · 동아 문화 `https://rss.donga.com/culture.xml` ≈41 · 연합 연예 `https://www.yna.co.kr/rss/entertainment.xml` ≈20 · SBS 연예 `…sectionId=14…` ≈25 · 조선 문화·라이프 `…/category/culture-life/?outputType=xml` ≈13 | Guardian Culture `https://www.theguardian.com/culture/rss` en 8.7(실측) · NYT Arts `https://rss.nytimes.com/services/xml/rss/nyt/Arts.xml` en ≈14 |
| 스포츠 | ★연합 스포츠 `https://www.yna.co.kr/rss/sports.xml` ≈64 · SBS 스포츠 `…sectionId=09…` ≈39 · 동아 스포츠 `https://rss.donga.com/sports.xml` ≈13 | BBC Sport `https://feeds.bbci.co.uk/sport/rss.xml` en 9.7(실측) · ESPN `https://www.espn.com/espn/rss/news` en ≈14 |
| 기후·환경 | (국내 전용 피드 못 찾음) | Guardian Environment `https://www.theguardian.com/environment/rss` en 2.6(실측) · Carbon Brief `https://www.carbonbrief.org/feed/` en 0.3(실측) · Inside Climate News `https://insideclimatenews.org/feed/` en ≈4 |

**죽었거나 쓰기 어려운 주소**(검증 결과, `feeds.json` `alive:false`):
- 정책브리핑 `korea.kr/rss/policy.xml`, 연합 `rss/it.xml`, 동아사이언스, 사이언스타임즈, 한겨레 기후, Korea JoongAng Daily, NHK World 영어: 모두 404.
- 뉴스1·디지털데일리: RSS 주소가 HTML 페이지를 돌려준다.
- JTBC 속보: 2024-10-29 이후 갱신이 멈췄다.
- NHK 일본어: 2026-08-08 이후 갱신이 멈췄다.
- 경향 IT: 2025-03 이후 갱신이 멈췄다.
- 헬로디디: `<author>` 안 꺾쇠 때문에 XML이 깨진다.
- 중앙·KBS: 공식 RSS 페이지를 찾지 못했다.

**피드 품질 주의**(G-4와 이어짐):
- 한겨레(전 섹션): 글 날짜가 없다.
- 매일경제·코리아헤럴드: 7~9시간 미래 시각이 찍힌다.
- 노컷: 월이 숫자인 날짜를 쓴다.
- 조선 Arc 섹션 피드: 글 수가 적다.

### (다)-3 알림 과잉 방지 — 제안 묶음

검증으로 본 규모: 국내 종합 출처 하나의 '전체' 피드는 낮 시간대 기준 시간당 수십 건이다. 분야 3개를 국내 출처 2곳씩으로만 켜도 하루 수백 건이 들어온다. 사람이 감당하는 알림은 하루 몇 건 수준이다(매체 앱 평균 BBC 8.3건·NYT 10건, [Guardian 2025](https://www.theguardian.com/media/2025/jun/20/increase-alert-fatigue-phone-users-disable-news-notifications-study-finds) — 수치는 검색 요약 기준이라 원문 대조 필요).

1. **알림 단위를 '출처'에서 '분야 × 중요도'로 옮긴다.** 매거진에는 전부 싣고, 물방울은 다음 중 하나일 때만 떨어뜨린다.
   - 분야 알림이 켜져 있고 D-1 문턱(기본 국내 3곳·해외 2곳)을 넘은 소식
   - 공식 발표 등급 출처의 소식
   - ★꼭 알림 낱말이나 따라가는 이야기(D-5)에 걸린 소식
2. **K-03 고치기.** "하루 15건 넘으면 알림 끔"은 국내 언론에 맞지 않는다. 일반 뉴스 출처는 기본값을 '매거진만'으로 두고, 알림 여부는 분야 단위로 정한다.
3. **분야별 모드**: 즉시 / 묶음(정한 시각에 한 방울, D-2) / 매거진만. 첫 실행 기본값은 고른 분야 중 최대 2개만 '즉시'로 둔다.
4. **분야별 하루 상한**(기본 3, 전체 상한 10)을 둔다. 넘친 소식은 고여서 다음 묶음 시각에 나간다. 문턱을 크게 넘은 소식(예: 국내 8곳 이상)만 상한을 무시한다.
5. **같은 이야기는 한 번만** 알린다(지금 C-15의 36시간 규칙 유지). 새 보도가 붙어도 다시 알리지 않는다. 단, 따라가는 이야기(D-5)는 예외다.
6. **카드에서 바로 줄이기**(G-3): "이 분야 덜 받기 / 이 출처 숨기기 / 이 낱말 알리지 않기"를 둔다. 줄인 결과는 다음 알림부터 바로 반영한다.
7. **주간 알림 점검**: 일요일 저녁에 "이번 주 물방울 34번, 그중 연 것 9번 — 사회 분야를 묶음으로 바꿀까요?"를 한 번만 묻는다. 근거: 알림을 받지 않는 사람의 15%는 앱을 설치할 때 바로 껐다([Press Gazette DNR 2025](https://pressgazette.co.uk/publishers/digital-journalism/mobile-news-alerts-push-notifications-digital-news-report-2025/)). 처음 몇 주에 조정해 주는 것이 끄기를 막는다.
8. 방해 금지(C-19)·잠시 끄기(C-20)는 그대로 둔다. 회의·전체 화면 감지(D-8)를 더한다.

### (다)-4 저작권·약관 — 결정 필요

- **국내 RSS 이용 조건**: 공식 RSS 안내가 있는 곳은 거의 다 "개인·비상업적 이용만, 상업적 이용은 사전 허락"을 명시한다. 연합([안내](https://www.yna.co.kr/rss/index)), 경향([안내](https://www.khan.co.kr/help/help_rss.html)), 동아([안내](https://rss.donga.com/)), 서울경제([안내](https://www.sedaily.com/RSS)), SBS([안내](https://news.sbs.co.kr/news/rss.do)), 노컷([안내](https://www.nocutnews.co.kr/rss/))이 그렇다.
- **AI 학습·활용 금지 표기**: 동아·SBS·서울경제는 'AI 학습 이용 금지'를 걸었다. 한겨레는 피드에 직접 **"무단 전재, 재배포, AI 학습 및 활용 금지"**라고 적었다(검증 때 `<copyright>`에서 확인).
- **한국언론진흥재단 이용규칙**([KPF](https://www.kpf.or.kr/front/board/boardContentsView.do?board_id=291&contents_id=855b0c963b5c4a42ba6b26d06c7186d4)):
  - RSS는 개인 구독용이고, 공중 배포와 재RSS는 금지다.
  - 직접 링크는 허용된다.
  - **프레임 링크(자기 화면 안에 기사를 띄우는 방식)는 손해배상 위험**이 있다. Dropcap 읽기 창(R-01~R-04 본문 추출·전문 번역)이 여기에 가깝다.
- **결정이 필요한 것(관리자·사용자)**:
  1. 국내 언론 기본 출처를 앱에 담아 배포할지(C-01 방식), 아니면 **추천 목록에서 사용자가 직접 켜는 구조**(개인 RSS 리더 성격)로 할지.
  2. 국내 언론 기사를 읽기 창 전문으로 보여 줄지, 아니면 **제목·요약 + 원문 열기**를 기본으로 할지. 해외 기사 번역은 지금처럼 하더라도, 'AI 활용 금지' 표기 출처(한겨레 등)는 기기 안 요약·사실형 제목(D-7)에서 뺄지.
  3. 앱이 유료이거나 광고가 붙으면 '상업적 이용'으로 해석될 여지가 커진다. 이때는 매체 제휴나 재단 이용 계약이 선행되어야 한다.

  M-22(저작권 안내 문구)만으로는 부족하다. 법률 자문 전에는 2를 '원문 열기 기본'으로 두는 쪽이 안전하다.

---

## (라) 추천 우선순위 TOP 5 (빨리 되고 효과가 큰 순)

| 순위 | 무엇 | 왜 지금 | 크기 |
|---|---|---|---|
| 1 | **온보딩 + 분야 체계 + 분야별 알림 켜기/끄기**(G-1, G-2, (다)-1·2) | 일반 뉴스 전환 그 자체다. 이것 없이 출처만 늘리면 첫날 홍수가 난다 | 중 (뷰 1개 + `sources.json` 필드 + 설정 탭) |
| 2 | **알림 과잉 방지 묶음: 중요도 문턱 + 분야별 상한 + 넘치면 고였다 한 방울**(D-1, D-2, (다)-3 1~5) | 국내 출처 피드량(하루 수백 건)을 보면 필수다. 이미 있는 "외 N곳"·아침 브리핑을 재사용하므로 빠르고, 물방울 정체성이 가장 잘 드러난다 | 하~중 |
| 3 | **피드 내성: 날짜 없음·미래 시각·비표준 날짜 처리 + 출처 건강 표시**(G-4, G-5) | 이번 검증에서 국내 주요 출처(한겨레·매경·노컷)가 실제로 걸렸다. 고치지 않으면 3일 규칙·정렬·호 엮기가 조용히 틀어진다. 반나절 작업 | 하 |
| 4 | **카드·알림에서 바로 줄이기 + 묶음 안까지 완전 차단**(G-3, (다)-3 6) | 경쟁 앱 불만 1순위(숨겨도 다시 나옴, 키워드 뮤트 없음)를 바로 겨냥한다. 이미 있는 거르기 로직을 앞으로 꺼내기만 하면 된다 | 하 |
| 5 | **해외·국내 같은 이야기 나란히**(D-3) | 경쟁 앱 누구도 하지 않는다(포털은 국내만, Particle·Ground는 영어권만). Dropcap에는 이미 언어를 넘는 같은 소식 판단(StoryMatch·titleEn)과 번역이 있다. '국제' 분야에서 바로 차별점이 보인다 | 중 |

다음 후보:
- OPML 가져오기·내보내기와 Obsidian 자동 저장(G-6, G-9, D-12): 하루 이내 작업으로 신뢰를 얻는다.
- 이야기 따라가기(D-5)
- 분야별 물빛 물병(D-10)

모든 순위에 앞서 **(다)-4 저작권 결정**을 먼저 받아야 1·5번의 기본 출처 구성이 정해진다.

---

## 부록: 조사 한계

- Reddit 원문 스레드는 검색 도구가 막혀 인용하지 못했다. 불만 비율(유료벽 21% 등)은 2차 분석 블로그 하나의 값이다.
- Artifact 종료 공지 원문(Medium)은 403이라 TechCrunch 인용으로 대신했다.
- 네이버 언론사·기자 구독 알림의 현재 사양, 중앙·KBS 공식 RSS, Bloomberg·키움 알림 세부 메뉴는 확인하지 못했다.
- 하루 글 수는 한 시점의 피드에서 추정한 값이다. 출처 선택 전에 며칠 동안 다시 재는 것이 좋다(같은 방식으로 `feeds.json` 갱신 가능).
