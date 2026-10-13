# Dropcap

> 드롭캡(dropcap): 잡지 첫 글자를 크게 키우는 조판 방식. 그리고 상단바에서 똑 떨어지는(drop) 소식.

공신력 있는 AI 소식을 모아 보는 macOS 매거진·알림 앱입니다. 새 소식이 올라오면 상단바에서 **물방울이 맺혔다가 똑 떨어지고**, 떨어진 자리의 유리 카드에 **물이 찰랑찰랑 차오르며** 알려 줍니다. 카드를 누르면 광고 없이 본문만 추린 읽기 창이 열리고, 영어 기사는 한국어로 번역해 보여 줍니다.

> Dropcap is a macOS menu-bar magazine that watches trusted AI news sources and drips a Liquid Glass notification from the menu bar when something new is published. Articles open in a clean reader with Korean translation.

- macOS 14 이상 (Liquid Glass·기기 내 번역·3줄 요약은 macOS 26 이상)
- Swift · SwiftUI · AppKit 네이티브(글꼴 포함 앱 크기 약 9MB)
- Windows 네이티브 판은 준비 중입니다.

## 기능

**AI 매거진** (⌥⌘M)
- 오늘 호 · 이번 주 호 · 지난 호(매일·매주 자동 발행). 표지 기사(큰 사진, 천천히 다가오는 켄 번스 효과) + 분야별 지면 + 구독 채널 지면(영상·논문·릴리스·커뮤니티·팟캐스트).
- 편집 점수: 공식 발표 · 여러 곳 보도 · ★ 중요 낱말 · 내가 자주 읽는 분야·출처 · 최신성. 정렬: 추천순 / 최신순 / 많이 보도된 순 / 출처별.
- 스토리: 같은 소식을 다룬 여러 곳을 한 줄기로 묶어 타임라인으로(영어·한국어 기사도 뜻으로 이어 줌 — 기기 내 문장 임베딩).
- 스크랩북: 읽기 창에서 문단에 마우스를 올려 ✂︎ 로 문단 스크랩, 기사 전체 스크랩, 폴더·메모, 폴더째 Markdown 복사·저장.
- 저장(나중에 읽기)은 번역까지 이 Mac 에 보관해 오프라인으로 읽기. 전체 기록 검색.
- 움직임: 지면이 차례로 깔리고, 카드에 마우스를 올리면 사진이 살짝 따라 움직이며, 책장 넘기듯 지면이 바뀌고, 누른 카드에서 읽기 창이 커져 나옵니다.

**알림**
- 상단바 아래에 물이 맺혀 부풀다가 톡 떨어지고(Liquid Glass), 유리 카드에 물이 찰랑찰랑 차오르며, 기사 사진이 물속에서 인화되듯 떠오릅니다.
- 마우스가 있는 디스플레이의 위쪽 가운데(노치가 있으면 노치에서). 떠 있는 동안 다른 화면으로 커서를 옮기면 따라갑니다.
- 남은 물이 천천히 빠지며 남은 시간을 보여 주고, 마우스를 올리면 멈추고 나중에 읽기·브라우저 단추가 나옵니다.
- 같은 소식은 한 번만("외 N곳"), 분야 태그, ★ 꼭 알림 / 알리지 않음 낱말, 방해 금지 시간, 알림 잠시 끄기, 채널별 알림 켜기·끄기. 시스템 알림 센터 방식도 선택 가능.

**구독 채널**
- 추천 목록: YouTube(OpenAI·Anthropic·DeepMind 등), 뉴스레터·블로그(Import AI·Latent Space·Simon Willison 등), 연구소, arXiv, GitHub 릴리스(Ollama·vLLM·llama.cpp·Claude Code 등), Hacker News·Reddit, 국내 기술 블로그·매체, 팟캐스트.
- 아무 주소나: 웹사이트(피드 자동 발견), Substack·Medium, YouTube 채널·@핸들·재생목록, GitHub 저장소, `r/서브레딧`, `cs.AI` 같은 arXiv 분류.
- 글이 많은 채널은 알림 없이 매거진에만 싣는 것이 기본. 영상·팟캐스트는 원래 앱으로 엽니다.

**읽기**
- Mozilla Readability 로 본문만 추립니다(HTML 만 받아 먼저 시도, 스크립트가 필요한 사이트는 열 때만).
- 원문을 먼저 보여 주고 번역이 위에서부터 바뀝니다. 번역/원문 전환, 글자 크기(⌘- / ⌘=), 읽는 시간, 소리 내어 읽기, 3줄 요약(Apple Intelligence).

**그 밖에**
- 상단바 창: 전체 / 안 읽음 / 저장, 검색, 분야 거르기, 정렬, 모두 읽음
- 아침 브리핑, ⌥⌘N(가장 최근 안 읽은 소식), 글꼴 Pretendard(설정에서 시스템 글꼴로)

## 출처

`shared/sources.json` 에 있습니다. 설정 › 출처에서 켜고 끌 수 있습니다.

| 구분 | 기본으로 켬 | 기본으로 끔 |
|---|---|---|
| 공식 발표 | OpenAI, Anthropic, Google DeepMind, Google AI, NVIDIA(AI 글만) | Hugging Face, AWS Machine Learning |
| 언론 | MIT Technology Review, Ars Technica, The Verge | TechCrunch, WIRED |
| 국내 | AI타임스 | 전자신문(AI 글만) |

처음 켠 출처는 기존 글을 기억만 하고, 그 뒤에 올라온 글부터 알립니다. 서버에 부담을 주지 않도록 ETag·Last-Modified 로 바뀐 것이 있을 때만 받아 옵니다(기본 5분 간격).

## 번역과 개인정보

- **번역**: 영어→한국어 언어 자료가 이 Mac 에 있으면 Apple 기기 내 번역(Translation 프레임워크)을 씁니다. 없으면 Google 번역 공개 엔드포인트를 씁니다. 이 경우 기사 문장이 Google 로 전송되며, 공식 API 가 아니라 언제든 막힐 수 있습니다. 설정 › 일반 › "기기 내 번역 자료 받기"로 바꿀 수 있습니다.
- **요약**: Apple Intelligence(기기 내 모델)만 씁니다. 외부 AI 서비스로 보내지 않습니다.
- **저장 위치**: `~/Library/Application Support/Dropcap/` — 설정(native-state.json), 매거진·스크랩 기록(magazine.sqlite), 기사·사진 캐시. 계정·분석·추적 없음. magazine.sqlite 를 지워도 알림 기능은 그대로 동작합니다.
- **안전**: 피드에서 온 주소는 믿지 않습니다. 공개 인터넷 주소만 받고(이름을 실제 IP 로 풀어 확인, 접속한 IP 도 다시 확인), 알림 때 미리 받기는 사이트 스크립트를 돌리지 않습니다.

## 빌드

Xcode 26 이상(Swift 6)이 필요합니다.

```bash
cd mac
swift build            # 개발용 빌드
swift test             # 시험
./scripts/build.sh     # build/Dropcap.app 과 build/Dropcap-<버전>.dmg (Apple 실리콘·Intel 공용)
```

개발자 인증서가 없으면 이 Mac 전용 임시 서명으로 만들어집니다. 다른 Mac 에서 열 때는 시스템 설정 › 개인정보 보호 및 보안 › "그래도 열기"가 필요합니다. 인증서가 있으면 `MAC_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build.sh`.

시험용 환경 변수:

```bash
DROPCAP_TEST_TOAST=1 .build/debug/Dropcap                 # 실행하자마자 알림 미리 보기
DROPCAP_TEST_URL=<기사 주소> .build/debug/Dropcap          # 읽기 창 바로 열기
DROPCAP_TEST_MAGAZINE=1 .build/debug/Dropcap               # 매거진 바로 열기
DROPCAP_DATA_DIR=/tmp/ainews-test .build/debug/Dropcap     # 실제 기록을 건드리지 않는 시험용 폴더
DROPCAP_LIVE_TESTS=1 swift test                                # 실제 서버로 피드·주소 해석 시험
```

## 구조

```
shared/sources.json        출처 목록(맥·윈도우 공용)
mac/
  Sources/Dropcap/
    Core/      피드 받기·해석, 안전 검사, 번역, 요약, 분야, 구독 채널, 매거진 편집·DB, 스크랩, 상태 저장, 단축키
    Toast/     물방울(DripView) · 물 차오름(WaterFill) · 알림 카드와 패널
    Reader/    본문 추출(Readability), 미리 받기·캐시, 읽기 창, 소리 내어 읽기
    UI/        매거진, 상단바 창, 설정, 글꼴, 사진 로더
  Resources/   Info.plist, Readability.js, Fonts/(Pretendard)
  Tests/       시험
  scripts/     빌드·아이콘
```

## 라이선스

[MIT](LICENSE). 포함된 외부 코드는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 를 보세요.

기사 내용의 저작권은 각 언론사·기업에 있습니다. 이 앱은 원문 링크로 이어 주며, 본문을 다시 배포하지 않습니다.
