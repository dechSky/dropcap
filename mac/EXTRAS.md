# 남은 개선 묶음 (wt/extras)

유료 기사 표시·무료 보도 안내 · 회의 중 자동 조용히 · 오늘 호 완독 · 분야별 저녁 정리 · 분야 대표 사진 점수.
기능 번호는 `docs/FEATURES.md` 에 새로 붙였다(G-14·G-15·N-25·N-26·M-23·M-24). 윈도우·리눅스 열은 ☐.

## 1. 유료 기사 표시 + 무료 보도로 안내 (G-14 · G-15 · 근거 G-11·D-9)
- `shared/sources.json` 에 `paywall` 필드(`hard` · `metered`): WSJ Markets=hard, NYT 6곳·MarketWatch·WIRED 2곳·New Scientist·STAT=metered. 다른 앱(윈도우 C#·리눅스 Rust)은 모르는 필드를 무시하므로 그대로 읽힌다.
- 직접 추가한 출처는 주소 도메인 표(`Paywall.knownDomains`: FT·Economist·WSJ·Bloomberg·Barron's·The Times·The Information·Nikkei = hard, NYT·WaPo·Atlantic·New Yorker 등 = metered, 하위 도메인 포함).
- 배우기: 사용자가 **연** 기사의 본문 추리기 결과를 출처별로 DB `extract_stats`(magazine.sqlite, `CREATE TABLE IF NOT EXISTS` 라 예전 파일에도 그대로 생김)에 쌓는다. 실패 = 본문 못 추림, 막힘 = 1500자 미만 맛보기에 구독 권유 문구(`Paywall.wallPhrases`). 5번 이상 · 60% 넘게 막히면 '자주 막히는 곳'. 50번 넘으면 반으로 줄여 최근 결과를 크게. 미리 받기(스크립트 없이)는 세지 않는다.
- 자물쇠(`PaywallMark`): 상단바 목록 줄(기본·카드·히어로·타임라인), 매거진 카드·표지, 스토리 타임라인. hard·배움 = 잠긴 자물쇠, metered = 열린 자물쇠, 마우스를 올리면 이유.
- 읽기 창(`FreeAlternativesBox`): hard·배움 기사를 열었을 때, 또는 본문을 못 열었거나 맛보기만 나왔을 때 머리 아래에 "같은 소식을 무료로 읽기: 출처·출처" — 같은 스토리 보도 중 유료·숨긴 출처가 아닌 기사(출처마다 하나, 공식 발표 > 국내 > 언론, 최신, 3개). 누르면 그 기사 읽기 창. '원문 그대로 열기'와 기존 실패 화면의 '원문 열기'는 그대로.
- 파일: `Core/Paywall.swift`(새) · `UI/PaywallViews.swift`(새) · `Reader/ArticleService.swift`(기록 3줄, `PreparedArticle.paywalled`) · `Reader/ReaderView.swift` · `Core/Database.swift` · `Core/Models.swift`·`Core/Sections.swift`(필드 1줄씩) · `UI/MenuView.swift`·`UI/MenuStyles.swift`·`UI/MagazineView.swift`(자물쇠 1줄씩).

## 2. 회의·발표 중 자동 조용히 (N-25 · 근거 D-8)
- 감지(`Core/FocusGuard.swift`, 공개 API 만):
  - 전체 화면: 앞에 있는 **다른** 앱의 보통 창(layer 0)이 화면 하나의 크기와 같음(CGWindowList — 창 이름은 읽지 않아 화면 기록 권한이 필요 없다). 메뉴 막대 아래까지만 키운 창은 아님. Dropcap 자신의 창은 뺌.
  - 화면 공유·기록: 그때만 떠 있는 도우미 프로세스 이름(libproc) — Zoom 공유 `CptHost`, 화면 기록 `screencaptureui`, 화면 공유 앱 `ScreenSharingAgent`·`SSInvitationAgent`. Zoom 이 켜져 있기만 하거나 `sharingd` 는 해당 없음. Google Meet·Teams 브라우저 공유는 공개 API 로 알 수 없어 '전체 화면'이나 '캘린더'로만 잡힌다.
  - 캘린더: EventKit, 지금 진행 중이고 하루 종일·'한가함'·거절한 일정이 아닌 것. **설정에서 켤 때만** 전체 접근 권한을 묻고, 거절하면 꺼진 채로 둔다. `Info.plist` 에 `NSCalendarsFullAccessUsageDescription` 추가.
- 동작: `AppModel.isHushed` = 방해 금지 시간 · 잠시 끄기 · 위 감지. 확인(checkAll)·묶음·팔로우 스토리 알림·아침 브리핑이 모두 이것을 본다 → 방해 금지와 똑같이 물방울 없이 '안 읽음'에 쌓이고 떨어질 소식은 그 분야 묶음으로 고인다. 손으로 새로고침은 그대로 알림. 감지 결과는 15초 기억, 설정을 바꾸면 비움.
- 설정 '일반 › 회의·발표 중에는 조용히': 전체 화면(기본 켬)·화면 공유(기본 켬)·캘린더(기본 끔). 예전 상태 파일은 없는 값을 기본값으로 읽는다. 상단바 머리에 이유 아이콘(방해 금지 달 자리).

## 3. 오늘 호 완독 (M-23 · 근거 D-11)
- 대표 기사(`TodayIssue.keys`): 표지 + 주요 뉴스 지면 첫 줄 3건 + 고른 분야 지면마다 첫 줄 3건(겹치면 한 번, 구독 채널·그 밖의 소식·고르지 않은 분야는 뺌).
- 매거진 오늘 호 머리 아래 '오늘 호 대표 기사 n/m' 작은 막대. 다 읽으면 '오늘 호를 다 읽었어요' + "다음 호는 내일 오전 9시 브리핑으로 알려 드릴게요"(브리핑을 끄면 '내일 아침'). 그날은 '새 소식이 들어왔어요' 띠를 띄우지 않는다. 한 번 끝나면(UserDefaults `todayIssueDone` = 날짜) 표지가 바뀌어도 그날은 끝난 호.
- 파일: `Core/TodayIssue.swift`(새) · `UI/TodayViews.swift`(새) · `UI/MagazineView.swift`(IssueView 몇 줄).

## 4. 분야별 저녁 정리 (N-26 · 근거 D-13)
- 모드가 '묶음'인 분야는 묶음을 보낼 때(`deliverBundles`) 근거 기사(8건까지)를 `state.briefs[분야]` 에 두고, Apple Intelligence 가 있으면 `Summarizer.briefing` 으로 "오늘 이 분야에서 무슨 일이 · 왜" 3줄. 모델에는 원제목(+한국어 제목)·출처·요약만 주고, **줄마다 근거 번호 [n]** 을 달게 해 번호 없는 줄·범위 밖 번호는 버린다.
- 매거진 그 분야 지면(묶음 알림을 누르면 가는 곳) 맨 위 '저녁 정리' 상자: 기기 안 요약 표시, 줄마다 [n], 아래에 근거 기사 원제목·출처(누르면 읽기 창, 마우스를 올리면 주소). 그날만 보인다.
- **알림 문구는 바꾸지 않았다**(제목 2줄 그대로, 요약을 알림에 쓰지 않음 — D-7 원칙). 모델이 없으면 상자도 없다.
- 이 Mac 은 Apple Intelligence 가 꺼져 있어(`appleIntelligenceNotEnabled`) 실제 요약 문장은 확인하지 못했다. 상자 모양은 시험 견본 문장으로 확인. 파싱·프롬프트는 단위 시험.

## 5. 분야 대표 사진 점수 (M-24)
- `PhotoQuality.score`: 비율 15% + 크기 15% + 글자 면적 40%(Vision 글자 **인식** 한·일·중·영, 3% 까지 감점 없음) + 색 다양성 30%(48×48 에서 넓은 네 색의 몫). 글자 20% 이상 · 단색 바탕 35% 이상(96×96 에서 이웃과 똑같은 칸) · 단색 25% 이상 + 글자 5% 이상이면 반으로. **0.55 미만은 대표 사진으로 쓰지 않는다.**
  - 처음엔 글자 '사각형' 찾기(VNDetectTextRectangles)를 썼는데 흐린 얼굴·무늬를 글자로 잡아(작은 인물 사진 29%) 실제 인식으로 바꿨다. 언어를 잘못 짚으면 신뢰도가 0.3 으로 떨어져 0.3 까지 센다.
  - 실제 피드 사진 50장 + 앱 화면 캡처 4장으로 맞춤: 사진 36장 통과, 뺀 것 = 큰 글자 그림('4', 'AI'), 로고 위주(Anthropic 간판·OpenAI·Shopify·Google Play·Xbox), 여백을 붙인 사진·아주 작은 사진, 증시 전광판, 앱 화면 캡처 4장 모두. 밤하늘처럼 어두운 사진(단색 0.21)은 통과.
- 쓰는 곳: `Editor.pickCover` — 매거진 표지는 사진이 좋은(또는 아직 재지 않은) 기사 중 1등, 없으면 사진 없는 기사(나쁜 사진을 크게 띄우지 않음). `Magazine.scoreImages` 가 최근 36시간 기사 사진을 사진 채우기 뒤에 16장씩 재어 DB `image_scores`(30일)에 둔다. 기사 카드·본문 사진은 그대로.
- **분야 카드용 API**: `SectionPhoto.pick(items)`(재 가며 고름, 비동기, 사진까지 돌려줌) · `SectionPhoto.best(items, scores:)`(잰 점수만). 분야 고르기 화면·`SectionCardLab` 은 관리자 작업 중이라 손대지 않았다 — 지금 `SectionCardLab.swift:12` 의 `items.first(where: { … image != nil … })` 를 `await SectionPhoto.pick(items.filter { $0.inSection(s.id) })` 로 바꾸면 된다.

## 시험
- `swift test` 169/169 통과. 새 `Tests/DropcapTests/ExtrasTests.swift`(25): 유료 판정 순서·도메인·배움 문턱·맛보기 감지·무료 보도 고르기·sources.json 계약·DB 기록과 반으로 줄이기 / 전체 화면·공유·일정 판정, 예전 설정 파일 기본값, 감지 덮어쓰기 / 대표 기사 고르기·다음 호 문구·하루 표시 / 저녁 정리 파싱·프롬프트·상태 왕복 / 사진 점수(합성한 사진·화면 캡처·로고)·관문·표지 고르기·DB.
- 화면(시험 폴더 `DROPCAP_DATA_DIR`, 훅 `UI/ExtrasTestHooks.swift`, App.swift 1줄): WSJ 기사 읽기 창의 '같은 소식을 무료로 읽기' 상자, 매거진 카드의 자물쇠(WSJ Markets), 오늘 호 진행률 0/19 → 완독 띠, 정치 지면 저녁 정리 상자(견본 문장), 상단바 머리의 회의 중 아이콘. 실제 피드 502건 중 유료 표시 105건.
- 시험 훅: `DROPCAP_TEST_EXTRAS=<폴더>`(위 화면 + 분야별 사진 점수 파일) · `DROPCAP_TEST_ENABLE=<출처,…>` · `DROPCAP_TEST_FOCUS=fullscreen|sharing|calendar|none` · `DROPCAP_TEST_PHOTO_FILES=<폴더>`.

## 남은 것·주의
- 저녁 정리의 실제 요약 문장은 Apple Intelligence 를 켠 Mac 에서 한 번 봐야 한다.
- 무료 보도 추천은 기존 스토리 묶기를 그대로 쓴다. 시험 중 WSJ '데이터 센터 IPO 무산' 기사에 블로터 'IPO 앞둔 인텔리빅스' 기사가 같은 스토리로 묶여 추천됐다(묶기 기준의 느슨함 — 이번 범위 밖).
- 상단바 목록의 히어로 카드(맨 위 기사 사진)는 기사 자기 사진이라 점수를 적용하지 않았다(글자 그림이 크게 뜰 수 있음 — 원하면 `PhotoQuality.good` 으로 거를 수 있다).
- 화면 공유 감지는 공개 API 한계로 Zoom·화면 기록·화면 공유 앱만. 브라우저 화상회의 공유는 전체 화면·캘린더로 보완.
