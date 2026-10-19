# Dropcap — 윈도우 판

관심 분야(정치·경제·IT·AI 등)의 새 소식을 화면 위쪽에서 물방울이 떨어지듯 알려 주고, 매거진으로 엮어 보여 주는 트레이 앱입니다. 맥 앱(`mac/`)과 같은 기능·문구·수치를 윈도우 11 네이티브 앱으로 옮겼습니다. 기능 목록과 운영체제별 차이는 [`docs/FEATURES.md`](../docs/FEATURES.md)와 아래 '맥과 다른 점'에 있습니다.

## 구조

| 폴더 | 내용 | 어디서 빌드·시험 |
|---|---|---|
| `Dropcap.Core` | 피드 받기·해석, 안전 검사(S 절), 번역(Google), 같은 소식 묶기, 일반 뉴스 분야(`shared/categories.json`)·분야별 알림 정책, AI 하위 분류(`ai-topics.json`), 구독 채널, 상태 저장, 매거진 DB(SQLite), 스크랩, 앱 두뇌(AppModel) | 어디서나(`net10.0`) |
| `Dropcap.Ui` | 화면 데이터·명령 처리(웹 화면의 C# 쪽), 물방울 알림 엔진·그리기(SkiaSharp), 사진 로더, 소리 합성, 아이콘, 웹 화면(`web/`) | 어디서나(`net10.0`) |
| `Dropcap.Core.Tests` | xUnit 시험(맥 시험 사례를 옮긴 것 + 이 판의 시험) | 어디서나 |
| `Dropcap.App` | WinUI 3 앱 본체: 트레이, 트레이 창, 알림 창(레이어드 창), 읽기·매거진·설정 창(WebView2), 본문 추출기, 전역 단축키, 시스템 알림, 소리 내어 읽기 | 윈도우(맥은 컴파일 점검만) |
| `tools/IconGen` | 앱 아이콘을 코드로 그려 `.ico` 로(빌드 때 자동) | 어디서나 |

화면 규약은 [`Dropcap.Ui/PAGES.md`](Dropcap.Ui/PAGES.md).

## 윈도우에서 빌드·실행

준비: 윈도우 10(19041) 이상 · 윈도우 11 권장, [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0), WebView2 런타임(윈도우 11 은 기본 설치).

```powershell
cd windows
dotnet test Dropcap.slnx                                   # 핵심·화면 공용 시험
dotnet run --project Dropcap.App -r win-x64                # 실행(개발)
powershell -File scripts\package.ps1                       # 배포 압축본(Q-04) → windows\dist\Dropcap-win-x64.zip
```

`scripts\package.ps1 -Rid win-arm64` 로 ARM 판도 만듭니다. 압축을 풀고 `Dropcap.exe` 를 실행하면 됩니다(설치 없음, 자체 포함 — .NET·Windows App SDK 를 따로 깔 필요 없음).
데이터는 `%LOCALAPPDATA%\Dropcap\` 에 둡니다(`DROPCAP_DATA_DIR` 로 바꿀 수 있음). 지우면 처음 상태로 돌아갑니다.

## 맥에서 점검

```bash
cd windows
dotnet test Dropcap.slnx                                   # 시험(바깥 서버 시험은 DROPCAP_LIVE_TESTS=1)
DROPCAP_TOAST_FRAMES=/tmp/frames dotnet test Dropcap.slnx --filter ToastTests   # 물방울 장면을 PNG 로
scripts/check-on-mac.sh                                    # 윈도우 앱 C# 컴파일 점검(실행 파일은 안 만듦)
```

## 맥과 다른 점(운영체제 한계)

- **기기 내 번역 없음(T-05 ⊘)**: 윈도우에 무료 기본 기능이 없어 Google 번역만 씁니다.
- **요약(T-06)**: Apple Intelligence 대신 이 PC 의 Ollama 가 있으면 사용, 없으면 요약 칸을 숨깁니다. 앱이 내부망으로 요청하는 유일한 예외이며 주소(`127.0.0.1:11434`)는 고정입니다.
- **회의 중 캘린더(N-25 일부 ⊘)**: 설치 없이 푸는 앱이라 윈도우 일정 권한을 받을 수 없어, 전체 화면·Zoom 화면 공유만 알아봅니다.
- **저녁 정리(N-26)·사진 글자 인식(M-24)**: Apple Intelligence·Vision 대신 Ollama(있을 때만)·Windows.Media.Ocr.
- **노치 없음(N-12 ⊘)**: 천장은 커서가 있는 모니터의 작업 영역 위쪽(작업 표시줄이 위에 있으면 그 아래)입니다.
- **유리 재질(N-19 ~)**: 알림 카드는 반투명 색 바탕입니다(레이어드 창은 뒤 화면 흐림을 쓸 수 없음).
- **같은 소식의 '뜻' 비교(C-15 ~)**: 맥의 기기 내 문장 임베딩 대신 영어 제목의 고유명사 공유로 판단합니다(맥 시험 사례는 모두 같은 결과).
- **안전(S-03)**: 맥보다 강합니다 — 접속하는 순간(연결 콜백) 이름을 다시 풀어 모든 IP 를 검사하고, 검사한 그 IP 로만 접속합니다(DNS 바꿔치기로도 내부망 요청이 나가지 않음).

## 외부 코드

NuGet 으로 받는 것(배포본에 포함): Windows App SDK(MIT), SkiaSharp(MIT, Skia BSD-3), Microsoft.Data.Sqlite(MIT), SQLitePCLRaw(Apache-2.0, SQLite 공개 영역). 맥과 같은 자원(Pretendard OFL-1.1, Readability.js Apache-2.0)은 저장소 `THIRD_PARTY_NOTICES.md` 참고 — 빌드 때 `mac/Resources` 에서 앱 자원으로 복사됩니다.
