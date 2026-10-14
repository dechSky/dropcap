# Dropcap — 윈도우 판

관심 분야(정치·경제·IT·AI 등)의 새 소식을 화면 위쪽에서 물방울이 떨어지듯 알려 주고, 매거진으로 엮어 보여 주는 트레이 앱입니다. 맥 앱(`mac/`)과 같은 기능·문구·수치를 윈도우 11 네이티브 앱으로 옮겼습니다. 기능 목록과 운영체제별 차이는 [`docs/FEATURES.md`](../docs/FEATURES.md)(윈 열)에 있습니다.

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

## 윈도우에서 확인할 것(이 맥에서는 실행할 수 없음)

- [ ] 트레이 아이콘이 보이고, 안 읽은 소식이 있으면 채워진 신문 모양(밝은·어두운 작업 표시줄 모두). 누르면 아이콘 곁에 작은 창, 다른 곳을 누르면 닫힘.
- [ ] `DROPCAP_TEST_TOAST=1` 로 실행 → 커서가 있는 모니터의 작업 영역 위쪽 가운데에서 물방울이 맺혀 떨어지고, 카드에 물이 차오르며 "똑" 소리. 카드 밖 클릭은 뒤 앱으로 통과, 지금 쓰던 앱의 입력 초점이 그대로.
- [ ] `DROPCAP_TEST_BURST=1` → 3건이 0.32초 간격, 두 번째부터 바로 떨어짐. 마우스를 올리면 닫기·빠른 단추, 사라지지 않음.
- [ ] 알림이 떠 있는 동안 다른 모니터로 커서를 옮겨 0.25초 머물면 따라감. 모니터 배율이 다른 두 화면에서 글자가 흐리지 않음(PerMonitorV2).
- [ ] 전체 화면 앱·발표 중·집중 지원일 때는 물방울이 뜨지 않고 안 읽음에만 쌓임(N-23).
- [ ] 설정 › 접근성 › 시각 효과 › 애니메이션 효과를 끄면 물방울 없이 카드만 나타남·사라짐(N-24).
- [ ] Ctrl+Alt+N(가장 최근 안 읽은 소식), Ctrl+Alt+M(매거진). 다른 앱이 이미 쓰는 조합이면 등록되지 않음.
- [ ] 알림 방식 "시스템 알림" → 알림 센터에 최대 3건 + "N건 더", 누르면 읽기 창.
- [ ] 읽기 창: 원문이 먼저 뜨고 위에서부터 번역으로 바뀜, Ctrl+- / Ctrl+= 글자 크기, 소리 내어 읽기, 공유 창, 문단 스크랩. 알림 카드를 눌러 열면 카드 자리에서 커져 나옴.
- [ ] `DROPCAP_TEST_URL=<기사 주소>` 로 읽기 창 바로 열기. 스크립트로 본문을 그리는 사이트도 열림(느린 길).
- [ ] 매거진(`DROPCAP_TEST_MAGAZINE=1`): 작업 표시줄에 보이고, 표지 켄 번스·지면 넘김·스크랩북 Markdown 저장.
- [ ] 설정: 로그인할 때 자동 실행을 켜면 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Dropcap` 이 생김. Pretendard 끄기.
- [ ] Ollama(`http://127.0.0.1:11434`)가 켜져 있으면 읽기 창에 3줄 요약 상자, 없으면 숨김. 모델은 `DROPCAP_OLLAMA_MODEL` 로 고를 수 있음.
- [ ] 처음 실행(빈 `DROPCAP_DATA_DIR`) → 관심 분야 고르기 창. 고르면 그 분야 기본 출처만 켜지고 매거진이 채워짐(알림 없음). 설정 › 분야에서 다시 열림.
- [ ] `DROPCAP_TEST_SECTIONS=top,economy` · `DROPCAP_TEST_BUNDLE=economy` → "경제 7건" 묶음 물방울, 누르면 매거진 경제 지면(`DROPCAP_TEST_MAG_SECTION=economy`).
- [ ] 물방울·트레이 창 줄·매거진 카드 오른쪽 클릭 → 바로 줄이기(이 출처 숨기기·이 분야 덜 받기·이 낱말 알리지 않기).
- [ ] 트레이 창·매거진의 분야 칩 줄, AI 를 누르면 하위 칩. 스토리 상세의 해외·국내 두 칸, 팔로우.
- [ ] 두 번째 실행은 바로 끝남(하나만 실행).
- [ ] 잠자기에서 깨면 10초 뒤 확인.
- [ ] 유료 기사(G-14·G-15): WSJ·FT 등 기사 줄·매거진 카드에 자물쇠(무료 건수 제한은 열린 자물쇠), 마우스를 올리면 이유. 열면 읽기 창 머리에 '같은 소식을 무료로 읽기' 상자(같은 스토리가 있을 때), '원문 그대로 열기'.
- [ ] 회의·발표 중(N-25): 다른 앱을 전체 화면으로(F11·발표 모드) 띄우거나 Zoom 화면 공유 중이면 물방울 없이 안 읽음에 쌓이고 트레이 창 머리에 사람 아이콘. `DROPCAP_TEST_FOCUS=fullscreen|sharing|none` 으로 흉내.
- [ ] 매거진 오늘 호(M-23): 머리 아래 '오늘 호 대표 기사 n/m', 다 읽으면 '오늘 호를 다 읽었어요' 띠.
- [ ] 저녁 정리(N-26): Ollama 를 켜고 묶음 분야의 묶음이 나간 뒤 매거진 그 분야 지면 위에 3줄 + 근거 기사.
- [ ] 사진 점수(M-24): 화면 캡처·글자 그림이 표지·분야 카드에 뜨지 않음(글자 인식 언어팩 — 설정 › 시간 및 언어 › 언어에 한국어·영어).
- [ ] 분야 고르기·매거진 분야 머리의 유리 카드(흐린 사진·기울인 사진).
- [ ] 키보드: 트레이 창·매거진 J/K·Enter·S·O·M, 매거진 Ctrl+[ ·Ctrl+], 읽기 창 J/K(같은 창에서 바뀜)·Esc.
- [ ] 읽기 창 짧은 글(GeekNews 등)이 기다리지 않고 열림, 막는 사이트는 6초 안에 피드 요약 화면.

시험용 환경 변수(Q-03): `DROPCAP_DATA_DIR`, `DROPCAP_TEST_TOAST`, `DROPCAP_TEST_BURST`, `DROPCAP_TEST_URL`, `DROPCAP_TEST_MAGAZINE`(값이 있으면 그 지면), `DROPCAP_TEST_SETTINGS`, `DROPCAP_TEST_MENU`, `DROPCAP_TEST_SUBSCRIBE`(추천 채널 id 쉼표 목록), `DROPCAP_TEST_SECTIONS`(쉼표 목록 — 고르기 없이 고른 것으로), `DROPCAP_TEST_ONBOARD`, `DROPCAP_TEST_BUNDLE`(분야), `DROPCAP_TEST_MAG_SECTION`(분야), `DROPCAP_TEST_WELCOME`, `DROPCAP_TEST_FOCUS`(fullscreen·sharing·calendar·none — 회의 중 감지 흉내), `DROPCAP_REDUCE_MOTION=1`, `DROPCAP_DEVTOOLS=1`(웹 화면 개발자 도구).

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
