# 일반 뉴스 '매거진' 전환 — 앱 쪽(작업자 A)

기준: `docs/research/COMPETITIVE.md` (다)-1·(다)-3, 관리자 지시(분야 계약 형식). FEATURES 새 번호는 **G-01~G-13**, 고친 번호는 C-16·C-25·N-05·N-10·N-15·N-16·M-01·M-04·M-06·U-02·U-04·K-03(윈·리 열은 비움).

## 바뀐 것

| 무엇 | 파일 | FEATURES |
|---|---|---|
| 분야 모델 `NewsSection` + `shared/categories.json` 읽기(없으면 같은 내용의 내장 기본값) | Core/Sections.swift | G-01 |
| 출처의 `section`·`lang`·`region`·`defaultOn` 은 `Source` 를 고치지 않고 `sources.json` 에서 따로 읽음(`SourceMeta`) — 작업자 B 의 `Models.swift` 와 겹치지 않게 | Core/Sections.swift | G-01 |
| 기사의 분야: 출처 section 1순위 → '주요'·모름이면 낱말 규칙 → 그래도 모르면 주요. AI 는 다른 분야 글에서도 칩으로. 칩 여러 개·대표 하나 | Sections.place, `NewsItem.section/sectionChips` | G-02 |
| 분야별 알림 정책(순수 함수): 즉시/묶음/매거진만 × 문턱(국내 3·해외 2) × 공식 발표·★·팔로우 × 하루 상한(분야 3·전체 10) × 큰 소식(국내 8) → 알림/고임/매거진만. '주요 뉴스' 흐름 | Core/NotifyPolicy.swift | G-04~G-06, G-08 |
| 확인 흐름: 숨긴 출처 제외 → 매거진 → 같은 이야기 하나로 → 정책 결정 → 물방울 / 고임(`pending`) | AppModel.checkAll·decide | G-05~G-08 |
| 묶음 보내기: 분야 묶음 시각(기본 18시) 뒤 첫 분마다 확인, "경제 7건" 카드 → 누르면 그 분야 지면. 시스템 알림 방식도 | AppModel.deliverBundles, ToastCenter.showBundle, SystemNotifier.postBundle | G-07 |
| 상태: `sectionsChosen`·`sectionPolicy`·`hiddenSources`·`pending`·`notifyLog`·`notifiedStories`·`lastBundle`, 설정에 상한·문턱. 예전 파일 그대로 읽힘 | Core/Store.swift | C-13, G-03 |
| 기존 사용자 이전: 기록이 있고 분야를 고른 적 없으면 AI 만(즉시). 분야가 있는 새 출처는 그 분야를 골랐을 때만 기본으로 켬 | Store.prepare | G-03 |
| 첫 실행 관심 분야 고르기(카드·주요 뉴스 스위치·더 보기), 설정에서 다시 열기 | UI/SectionViews.swift OnboardingView | G-03 |
| 분야 칩 줄(상단바·매거진) + AI 하위 칩 | SectionChipBar | G-09 |
| 매거진 오늘 호를 분야 지면으로(주요 → 고른 분야 → 나머지), 옆 목록 '분야' | Magazine.sectionPages, MagazineView | G-10 |
| 바로 줄이기(출처 숨기기·분야 덜 받기·낱말 알리지 않기) — 카드·목록·물방울 오른쪽 클릭 | ReduceMenu, AppModel.hideSource/lessOf/muteWord | G-11 |
| 해외·국내 나란히(스토리 상세 두 칸, 카드 두 줄) | RegionSplit, Magazine.splitByRegion | G-12 |
| 설정 '분야' 탭 | SettingsView.sectionsTab | G-13 |
| 분야 표시: 카드·목록 칩이 분야 이름(AI 글은 'AI·모델'처럼) | `NewsItem.topicLabel`, TopicChip | N-05 |
| 문구: "오늘의 브리핑", 구독 칸 예시 | ToastView, SettingsView | N-16 |
| App.swift 는 `SectionStartup.run()` 한 줄 + 묶음 시스템 알림 누름 처리만 | App.swift, SectionViews.swift | — |

시험: `swift test` 73개(30묶음) 통과. 새 시험 `PivotTests.swift` 22개 — 정책 결정 표 15줄(분야 모드×문턱×상한), 주요 뉴스 흐름, 첫 실행 기본값, 묶음 시각, 예전 정책·상태 파일 읽기, 분야 정하기, 지면 순서, 해외·국내 나누기, 기존 사용자 이전. 견본 자료는 계약 형식 그대로 `mac/Tests/DropcapTests/Fixtures/`(categories.json · sources-sample.json 10곳).

## 화면 스냅샷(저장소에 올리지 않음 — 워크트리의 `mac/build/pivot-shots/`, .gitignore 대상)

- `onboarding.png` — 첫 실행 분야 고르기(`DROPCAP_TEST_ONBOARD=1`)
- `bundle.png` — 묶음 물방울 "경제 7건"(`DROPCAP_TEST_BUNDLE=economy`)
- `mag-40.png` — 분야를 고른 뒤 매거진 오늘 호(옆 목록 '분야', 표지 칩 'AI·연구')
- `menu-win.png` — 상단바 창의 분야 칩 줄
- 새 시험 훅: `DROPCAP_TEST_SECTIONS=top,economy`(고르기 없이 고른 것으로), `DROPCAP_TEST_ONBOARD`, `DROPCAP_TEST_BUNDLE=<분야>`, `DROPCAP_TEST_MAG_SECTION=<분야>`

지금 `shared/` 에는 B 의 자료가 아직 없어 분야 카드의 대표 출처가 '출처 준비 중'(AI 제외)이고, 지면도 AI 분야만 찹니다. B 병합 뒤 같은 훅으로 다시 찍으면 됩니다(코드 변경 없음 — 계약 형식은 견본 시험으로 확인).

## 결정이 필요했던 것(기본형으로 정해 둠)

1. **즉시 모드에서 문턱을 못 넘은 소식** → 고이지 않고 매거진에만(묶음에도 안 들어감). (다)-3 의 "물방울은 ~일 때만"을 그대로 읽음. 묶음에 넣으려면 `NotifyPolicy.decide` 의 `.quiet` 한 줄.
2. **기존 AI 사용자도 정책을 따름**: 예전엔 모든 AI 글이 물방울이었지만, 이제 공식 발표·해외 2곳·국내 3곳·★·팔로우만 바로 오고 나머지는 매거진. 예전처럼 다 받으려면 문턱을 1로.
3. **큰 소식 기준은 '국내 8곳'만**(해외만 다루는 분야엔 없음). 문서 그대로.
4. **묶음 시각 기본 18시**(분야마다 설정에서 6~23시). 방해 금지·잠시 끄기 중이면 끝난 뒤 첫 분에 보냄. 고인 지 36시간 지난 것은 버림.
5. **기사는 매거진 한 지면에만**(고른 분야 칩이 있으면 그 분야). AI 를 고르고 경제를 안 골랐으면 'AI 쓰는 은행' 기사는 AI 지면에.
6. **출처 숨기기는 매거진에서도 뺌**(알림만이 아니라). 설정 › 분야 › 숨긴 출처에서 되돌림.
7. **온보딩 모양**: 3열 카드 + 주요 뉴스 스위치의 기본형. 디자인 결정 요청을 따로 올림.

## 다음 작업(R-1·R-3·R-4·키보드)을 위해 잡아 둔 구조

- 정책 판단은 `NotifyPolicy`(순수 함수, 화면·DB 없음)와 `Magazine.sectionPages`(nonisolated static)로 떼어 두어, R-1 에서 엮기를 actor 로 옮길 때 그대로 가져갈 수 있다.
- 알림의 '같은 이야기'는 이제 **매거진 스토리 id**(`Magazine.clusterID`)로 판단한다(`notifiedStories`). 목록용 `groupSameStory`(36시간 recent 비교)는 '외 N곳' 표시용으로만 남았다 → R-4 에서 이것만 스토리 판단으로 바꾸면 하나로 합쳐진다.
- `decide` 는 확인 한 번에 `Store.save` 한 번만 부른다(R-3 묶기와 충돌 없음).
- `regionCoverage`·`resolve` 의 스토리별 DB 질의는 R-1 에서 한 번의 SQL 로 합칠 후보.
