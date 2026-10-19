# 시험

## 단위 시험

| 판 | 빌드 + 전체 시험 | 일부만 |
|---|---|---|
| 맥 | `cd mac && swift test` | `swift build --build-tests` 뒤 `swift test --skip-build --filter 'SuiteA\|SuiteB'` |
| 윈도우 | `cd windows && dotnet test Dropcap.slnx` | `dotnet test Dropcap.Core.Tests/Dropcap.Core.Tests.csproj --filter FullyQualifiedName~클래스` |
| 리눅스 | `cd linux && cargo test` | `cargo test --test core_tests`(작업공간 뿌리에서) |

- 바깥 서버를 쓰는 시험은 `DROPCAP_LIVE_TESTS=1` 일 때만 돕니다.
- 윈도우 앱 본체(`Dropcap.App`)는 맥에서 `windows/scripts/check-on-mac.sh` 로 컴파일만 점검합니다.

## 맥 끝에서 끝까지 시험

모두 임시 데이터 폴더·견본 피드·시험 시계로 돌고, 실제 기록과 네트워크를 쓰지 않습니다.

```bash
mac/scripts/e2e/run.sh [결과 폴더]          # 사용자 흐름 시나리오(묶음 시각·하루 상한·다시 시작·깨진 파일 복구)
mac/scripts/clicksweep.sh [결과 폴더]       # 화면 단추를 하나씩 누름(기본은 앱을 앞으로 띄우지 않는 조용한 모드)
mac/scripts/e2e/soak.sh [결과 폴더]         # 오래 켜 두기(며칠치를 시험 시계로)
mac/scripts/e2e/faults.sh [결과 폴더]       # 실패 처리(디스크 가득·DB 잠김 등)
mac/scripts/e2e/startup.sh <데이터> [결과]  # 시작 시간·첫 화면
```

## 사람이 직접 확인할 것(맥)

자동 시험이 닿지 않는 시스템 연동입니다.

- 위젯: 바탕화면 › 위젯 편집 › 'Dropcap' — 오늘의 표지·안 읽은 수가 보이고 누르면 읽기 창
- 단축어: '최신 소식 가져오기'·'주소를 나중에 읽기로 저장'·'매거진 열기'
- Spotlight 에서 저장한 기사 제목 → 읽기 창 · Safari 서비스 메뉴 'Dropcap 에 저장' → 확인 창
- 하루 쓰면서: 묶음 분야가 정한 시각에 한 방울로 오는지, 방해 금지·회의 중에는 안 읽음에만 쌓이는지
