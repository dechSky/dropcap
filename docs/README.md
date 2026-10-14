# 문서 지도

무엇을 어디서 찾는지. 기준 사실은 **코드와 [`FEATURES.md`](FEATURES.md)** 이고, `mac/*.md` 는 작업할 때 남긴 기록입니다(머리의 '상태' 줄에 지금 코드와 다른 점을 적어 둠).

## 처음 볼 것

| 문서 | 내용 |
|---|---|
| [`../README.md`](../README.md) | 앱 소개·기능·개인정보·맥 빌드·저장소 구조 |
| [`FEATURES.md`](FEATURES.md) | 세 판(맥·윈도우·리눅스)이 갖출 기능 전부와 판별 상태 — 기능 번호(C·G·S·T·N·R·M·U·P·K·H·D·Q·I)의 기준 |
| [`CHECKLIST.md`](CHECKLIST.md) | 자동 시험으로 못 보는 것을 사람이 직접 눌러 확인하는 목록(맥) |
| [`UPDATE-2026-10-14.md`](UPDATE-2026-10-14.md) | 마지막 문서 현행화 기록과 남은 어긋남(윈·리 PROGRESS) |

## 판별 안내

| 문서 | 내용 |
|---|---|
| [`../windows/README.md`](../windows/README.md) · [`../windows/PROGRESS.md`](../windows/PROGRESS.md) | 윈도우 판 구조·빌드·윈도우에서 확인할 것 · 진행 기록 |
| [`../windows/Dropcap.Ui/PAGES.md`](../windows/Dropcap.Ui/PAGES.md) | 윈도우 판 웹 화면 규약 |
| [`../linux/README.md`](../linux/README.md) · [`../linux/PROGRESS.md`](../linux/PROGRESS.md) | 리눅스 판 빌드·기능 스위치·리눅스에서 확인할 것 · 진행 기록 |

## 맥 작업 기록 (`mac/`)

| 문서 | 무엇을 찾을 때 |
|---|---|
| [`../mac/PIVOT.md`](../mac/PIVOT.md) | AI 전용 → 일반 뉴스 매거진 전환: 분야 모델, 분야별 알림 정책(즉시·묶음·매거진만), 분야 칩·지면(G-01~G-13) |
| [`../mac/FEEDS-DATA.md`](../mac/FEEDS-DATA.md) | 분야·출처 자료(`shared/`), 피드 날짜 내성, 출처 건강, OPML |
| [`../mac/AUDIT.md`](../mac/AUDIT.md) | 맥 앱 전체 버그 점검과 고친 것·남긴 제안(A-·R- 번호) |
| [`../mac/PERF-KEYS.md`](../mac/PERF-KEYS.md) | 매거진 편집을 화면 줄기 밖(Editor)으로, 저장 묶기, 같은 소식 통합, 키보드 탐색 — 전후 측정 |
| [`../mac/READER-SAVE.md`](../mac/READER-SAVE.md) | 읽기 창 모양, 아무 주소 저장(서비스 메뉴·스킴·북마클릿), 스크랩 노트 폴더 |
| [`../mac/WIDGETS.md`](../mac/WIDGETS.md) | 위젯·단축어·Spotlight 를 SwiftPM + build.sh 로 만드는 방법 |
| [`../mac/EXTRAS.md`](../mac/EXTRAS.md) | 유료 표시·회의 중 조용히·오늘 호 완독·저녁 정리·사진 점수(1차), 받는 크기 상한·지켜볼 낱말·내 기록 내보내기(2차) |
| [`../mac/E2E.md`](../mac/E2E.md) | 사용자 흐름 시나리오 시험(첫 실행 → 분야 → 알림 → 복구)과 돌리는 법 |
| [`../mac/READSWEEP.md`](../mac/READSWEEP.md) | 기본 출처 본문 추출 전수 점검(전·후 성공률), 실패 까닭별 안내 — [`../mac/readsweep/`](../mac/readsweep/) 에 기사별 표 |

## 조사

| 문서 | 내용 |
|---|---|
| [`research/COMPETITIVE.md`](research/COMPETITIVE.md) | 경쟁 앱 분석(일반 뉴스 매거진 전환 근거) |
| [`research/feeds.json`](research/feeds.json) | 출처 후보 조사 자료 |

## 자료 파일

- `shared/sources.json` — 기본 출처 120곳(분야·지역·유료 표시 포함), 세 판 공용
- `shared/categories.json` — 분야 12개(이름·기호·색)
- 맥 사용자 기록 위치: `~/Library/Application Support/Dropcap/` (윈도우 `%LOCALAPPDATA%\Dropcap\`) — 자세한 것은 루트 README '번역과 개인정보'
