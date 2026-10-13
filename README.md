# AI News Alert

공신력 있는 AI 소식이 올라오면 상단바에서 **물방울이 맺혔다가 똑 떨어지고**, 떨어진 자리의 유리 카드에 **물이 찰랑찰랑 차오르며** 알려 주는 macOS 메뉴바 앱입니다. 카드를 누르면 광고 없이 본문만 추린 읽기 창이 열리고, 영어 기사는 한국어로 번역해 보여 줍니다.

> A macOS menu-bar app that watches trusted AI news sources and drips a Liquid Glass notification from the menu bar when something new is published. Articles open in a clean reader with Korean translation.

- macOS 14 이상 (Liquid Glass·기기 내 번역·3줄 요약은 macOS 26 이상)
- Swift · SwiftUI · AppKit 네이티브, 앱 크기 약 2MB
- Windows 네이티브 판은 준비 중입니다.

## 기능

**알림**
- 상단바 아래에 물이 맺혀 부풀다가 목이 늘어나 끊어져 떨어지고, 유리 카드 바닥에 닿으면 물이 출렁이며 차오릅니다.
- 마우스가 있는 디스플레이의 위쪽 가운데에 뜹니다. 노치가 있는 MacBook 에서는 노치에서 떨어집니다. 알림이 떠 있는 동안 다른 화면으로 커서를 옮기면 따라갑니다.
- 카드에 남은 물이 천천히 빠지는 것으로 남은 시간을 보여 주고, 마우스를 올리면 멈춥니다. 마우스를 올리면 나중에 읽기·브라우저 버튼이 나옵니다.
- 여러 곳이 같은 소식을 다루면 한 번만 알리고 "외 N곳"으로 묶습니다(공식 발표 우선).
- 분야 태그: 모델·제품 / 연구 / 정책·규제 / 투자·기업 / 보안
- 꼭 알림 낱말(★ 중요) · 알리지 않음 낱말 · 방해 금지 시간 · 알림 잠시 끄기
- 시스템 알림 센터 방식으로도 바꿀 수 있습니다.

**읽기**
- Mozilla Readability 로 본문만 추립니다. HTML 만 받아 먼저 시도하고, 스크립트로 그리는 사이트만 실제로 띄웁니다(그림·동영상·글꼴은 막음).
- 알림이 뜨는 순간 뒤에서 본문·번역·요약을 미리 준비하고, 한 번 연 기사는 저장해 두어 다시 열면 바로 뜹니다.
- 원문을 먼저 보여 주고 번역이 위에서부터 차례로 바뀝니다. 번역/원문 전환, 글자 크기(⌘- / ⌘=), 소리 내어 읽기, 나중에 읽기.
- 3줄 요약: Apple Intelligence 가 켜져 있으면 이 Mac 안에서 만듭니다.

**그 밖에**
- 상단바 창: 전체 / 안 읽음 / 저장 탭, 검색, 분야 거르기, 모두 읽음
- 아침 브리핑: 매일 정한 시각에 지난 하루 소식을 분야별로 정리
- ⌥⌘N: 어느 앱에서든 가장 최근 안 읽은 소식 열기
- RSS 출처 직접 추가

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
- **저장 위치**: `~/Library/Application Support/AI News Alert/` (상태 파일, 기사 캐시). 계정·분석·추적 없음.

## 빌드

Xcode 26 이상(Swift 6)이 필요합니다.

```bash
cd mac
swift build            # 개발용 빌드
swift test             # 시험
./scripts/build.sh     # build/AI News Alert.app 과 build/AI-News-Alert-<버전>.dmg (Apple 실리콘·Intel 공용)
```

개발자 인증서가 없으면 이 Mac 전용 임시 서명으로 만들어집니다. 다른 Mac 에서 열 때는 시스템 설정 › 개인정보 보호 및 보안 › "그래도 열기"가 필요합니다. 인증서가 있으면 `MAC_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build.sh`.

시험용 환경 변수:

```bash
AINEWS_TEST_TOAST=1 .build/debug/AINewsAlert                 # 실행하자마자 알림 미리 보기
AINEWS_TEST_URL=<기사 주소> .build/debug/AINewsAlert          # 읽기 창 바로 열기
```

## 구조

```
shared/sources.json        출처 목록(맥·윈도우 공용)
mac/
  Sources/AINewsAlert/
    Core/      피드 받기·해석, 번역, 요약, 분야, 상태 저장, 단축키
    Toast/     물방울(DripView) · 물 차오름(WaterFill) · 알림 카드와 패널
    Reader/    본문 추출(Readability), 미리 받기·캐시, 읽기 창, 소리 내어 읽기
    UI/        상단바 창, 설정, 아침 브리핑
  Resources/   Info.plist, Readability.js
  Tests/       시험
  scripts/     빌드·아이콘
```

## 라이선스

[MIT](LICENSE). 포함된 외부 코드는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 를 보세요.

기사 내용의 저작권은 각 언론사·기업에 있습니다. 이 앱은 원문 링크로 이어 주며, 본문을 다시 배포하지 않습니다.
