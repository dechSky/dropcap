# 앱 안정화(맥)

> 상태: 맥 반영(2026-10-16, wt/stability). 윈도우·리눅스는 점검만 하고 아직 안 고침(아래 '남은 것' 3).

오래 켜 두기·멈춤·실패 처리·시작 시간을 재고(측정 → 고침 → 다시 측정), 찾은 문제마다 고치기 전 실패 → 고친 뒤 통과하는 시험을 두었다.
시험은 모두 임시 데이터 폴더·견본 피드·시험 시계로 돌고, 앱 창을 앞으로 띄우지 않는다(조용한 모드).

## 시험 장치(새로 더함)

| 무엇 | 돌리는 법 | 하는 일 |
|---|---|---|
| 오래 켜 두기 | `bugak run --heavy -- mac/scripts/e2e/soak.sh [결과]` (SOAK_DAYS·SOAK_STEP_MIN·SOAK_POSTS) | 시험 시계로 며칠치를 빨리 돌리며 시험 1시간마다 메모리(footprint·resident)·열린 파일·스레드·DB·WAL·상태 파일·사진/기사 캐시·상태 항목 수·확인 시간·메인 최장 지연을 `soak.jsonl` 에. 1시간마다 오늘·이번 주·분야 지면·스토리·검색·읽기 창·사진, 6시간마다 매거진·읽기 창 여닫기. 끝에 `leaks`·`footprint`·`vmmap`·`lsof`·`heap`. (`E2E/E2ESoak.swift`) |
| 실패 처리 | `bugak run --heavy -- mac/scripts/e2e/faults.sh [결과]` | F1~F7 아래 표. 데이터 폴더를 64MB 디스크 이미지(Finder 에 안 보이게)에 두어 디스크 가득까지. (`E2E/E2EFaults.swift`, 견본 피드 고장 흉내 `E2EFeeds.setFault`) |
| 시작 시간·첫 화면 | `bugak run --heavy -- mac/scripts/e2e/startup.sh <큰 데이터 폴더> [결과] [시계 파일]` | 빈 데이터·큰 데이터(사본, 기본 출처 147곳 모두 켬) 각 두 번: 켬 → 앱 준비 → 첫 확인 끝, 매거진 창(오늘 두 번·스토리) 열 때 메인 최장 지연, 스토리를 여는 동안 `sample`. (`E2E/E2EProbe.swift`) |
| 단위 시험 | `swift test --filter "Stability|Stall|TranslateStall|ClockChange|StoryList|DBWriteFailure|KeywordSpeed"` | 아래 S1~S8 (`Tests/DropcapTests/StabilityTests.swift`) |

메인 지연은 뒤 스레드가 100ms 마다 메인 큐에 일을 넣고 실제로 돌 때까지 걸린 시간(`MainWatchdog`). 숫자는 디버그 빌드(`swift build`) 기준이라 배포 빌드보다 느리다.

## 측정

### 오래 켜 두기(soak)

| 실행 | 조건 | 결과 |
|---|---|---|
| soak-trial(고치기 전) | 0.25일, 10분마다 확인, 확인마다 새 글 20건 | footprint 233 → **952MB**(6시간), 그중 CG Raster(풀린 사진) 520MB → S1 |
| soak-trial2(S1 뒤) | 같음 | 194 → 283MB(6시간), CG Raster 46MB |
| soak-4d-a(S1 뒤, S2~S8 전) | 4일, 15분마다, 확인마다 60건(하루 5760건 — DB 상한 20000건에 닿음) | 아래 표 |

soak-4d-a(시험 시각 기준):

| 시간 | footprint | resident | 파일 | 스레드 | DB | 상태 파일 | 사진 캐시 | 기사 캐시 | DB 기사 | 본 글 | 확인 평균 | 메인 최장 | 스토리 목록 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 259MB | 422MB | 84 | 19 | 0.1MB | 31KB | 29장 | 3 | 175 | 180 | 1.7초 | 414ms | 11ms |
| 24 | 279 | 409 | 84 | 19 | 4.6MB | 735KB | 567장·16MB | 67 | 5788 | 5947 | 3.5초 | 782ms | 265ms |
| 48 | 368 | 401 | 84 | 19 | 9.1MB | 840KB | 560장 | 150 | 11493 | 8000 | 3.9초 | 956ms | 546ms |
| 72 | 339 | 332 | 84 | 16 | 13.5MB | 827KB | 546장 | 150 | 17202 | 8000 | 4.2초 | 1225ms | 698ms |
| 96 | 353 | 388 | 84 | 15 | 16.0MB | 833KB | 560장 | 150 | 20000 | 8000 | 4.5초 | 1258ms | 937ms |

- 늘지 않음: 열린 파일(84)·스레드·사진 캐시(500~600장, 정리 500장)·기사 캐시(150)·본 글(8000 상한)·상태 파일(~0.8MB)·DB 기사(20000 상한에서 멈춤, DB 16MB). footprint 는 260~400MB 사이를 오르내림(최고 398MB).
- `leaks`: 413건 19KB — 모두 시스템 App Intents 연결(`com.apple.linkd.autoShortcut` NSXPCConnection 순환). 6시간·4일 같은 수(늘지 않음), 앱 코드 아님.
- 늘던 것: 스토리 목록 시간(11 → 937ms, 메인 스레드) → S5·S8. 메인 최장 지연 414 → 1258ms(매거진 창 열기) → S8.
- 견본 피드의 제목은 작은 낱말 묶음에서 뽑아 스토리 하나에 2000건 넘게 묶이는 일이 있었다(실제보다 큼 — 그래서 화면 멈춤이 크게 드러남).

### 실패 처리(faults-3, 고친 뒤 — 10/10 통과)

| 단계 | 결과 |
|---|---|
| F1 출처 일부 고장(503·깨진 피드·빈 응답·끊김·큰 피드 3000건·미래 날짜) | 확인 2.1초 · 메인 최장 12ms(고치기 전 726ms) · 고장 4곳 오류 기록 · 큰 피드·미래 날짜(지금으로 맞춤)·멀쩡한 곳 글 들어옴 |
| F1-회복 | 고장이 풀리면 밀린 글 들어옴 · 오류 비움 |
| F2 네트워크 전체 끊김 | 확인 0.3초(고치기 전 2.2초) · 오류 42/42 · 목록 그대로 |
| F2-회복 | 끊긴 동안의 글 들어옴 · 오류 비움 |
| F3 느린 출처 하나(25초) | 확인 25.2초(그만큼 늦지만 끝남) · 메인 72ms |
| F4-가 DB 잠김 1초 | 기다렸다가 넣음(고치기 전: 잠긴 동안 글이 매거진에서 영영 빠짐) |
| F4-나 DB 잠김 8초 | 풀린 뒤 다음 받아 넣기에서 다시 넣음 · 메인 10ms(중간 판에서 6.5초 멈췄던 것 → S7-나) |
| F5 디스크 가득(64MB 볼륨) | 죽지 않음 · 상태 파일 안 깨짐 · 비운 뒤 가득일 때 온 글까지 DB 에 들어감(고치기 전: 빠짐) |
| F6 잠자기 → 깨어나기 | 잠들 때 바로 저장 · 깨어나고 10초 뒤 확인(두 번 알려도 한 번) |
| F7 시계 이틀 전 → 열흘 뒤 → 제자리 | 확인·새 글 정상 · 열흘 뒤에 켠 1시간 잠시 끄기가 제자리에서 풀림(고치기 전: 열흘 남음) |

### 시작 시간·첫 화면(startup-3, 고친 뒤)

| 경우 | 앱 준비 | 첫 확인 끝 | 시작 중 메인 최장 | 매거진 열기 메인 최장(첫·다시·스토리) |
|---|---|---|---|---|
| 빈 데이터(처음 실행) | 0.2~1.1초 | 0.5~1.4초 | 2ms | 154~185 · 41~150 · 165~226ms |
| 큰 데이터(DB 20000건 · 본 글 8000 · 출처 147곳) | 0.18~0.20초 | 1.0~2.0초 | 4~13ms | 339~397 · 561~577 · 230~568ms |

고치기 전 큰 데이터: 매거진 첫 열기 1.3~1.8초, 스토리 화면 **9~19초** 메인 멈춤(startup-1·2). 앱 준비는 시험 모드의 didFinishLaunching 시점(시험 모드는 상단바 아이콘을 두지 않음 — 아이콘은 그 전에 SwiftUI 장면이 만든다). 남은 0.2~0.6초는 창 만들기(AppKit·SwiftUI) 자체.

## 찾은 것과 고친 것

| | 문제 | 고침 | 시험(고치기 전 실패 확인) |
|---|---|---|---|
| S1 | 사진 메모리 캐시(`ImageLoader`)가 장 수(160장)로만 묶여 풀린 사진(장당 3~5MB)만 수백 MB — 6시간 952MB | 풀린 크기 64MB 상한 최근 사용 순 캐시(`ImageMemoryCache`) | `imageMemoryCacheIsBoundedInBytes` |
| S2 | 아주 천천히 흐르는 피드 하나가 확인을 영영 묶음(요청 사이 대기 20초만 있고 전체 상한은 기본 7일) → '확인 중'이 풀리지 않아 그 뒤 확인이 모두 건너뜀 | 요청 전체 60초(`timeoutIntervalForResource`) | `slowDripFeedIsCutByDeadline`(로컬 서버) |
| S3 | 확인이 기다리는 제목 번역(구글)도 같은 꼴. 묶음이 실패하면 문단마다 다시 보내 상한을 수십 번 기다림 | 요청마다 20초 상한, 상한에 걸리면 1분 동안 구글을 부르지 않고 원문 그대로 | `silentTranslateServerFallsBackToOriginal`·`silentServerDoesNotMultiplyWaits` |
| S4 | 시계가 앞서 있을 때 켠 잠시 끄기가 시계를 바로잡은 뒤 며칠 남음 | 이틀보다 먼 끝은 풀린 것으로(`AppModel.snoozeActive`, 1분 점검이 지움) | `snoozeFromFutureClockIsReleased`, F7 |
| S5 | 스토리 목록을 메인에서 스토리마다 DB 두 번씩(보도 JSON 전부 풀기) — 4일 937ms, 상태가 바뀔 때마다 다시 | 문장 두 번(`Database.storyMembers`)·화면 줄기 밖(`Magazine.storyCards`), 카드에 보도를 넘겨 카드가 DB 를 다시 묻지 않음, `LazyVStack` | `storyListAsksDatabaseOnce`(300개에 문장 601번 → 2번) |
| S6 | 확인마다 피드 글 전부(수천)를 `@Published` 상태의 사전에 하나씩 넣어 그때마다 8000개 사전이 복사됨 — 큰 피드 한 번에 메인 726ms | 본 글·읽음 기억을 모아서 한 번에(`AppModel.markSeen`) | F1 메인 726 → 12ms(측정), 따로 잰 것: 3000건 114~195ms → 1~2ms |
| S7 | DB 잠김·디스크 가득 때 받은 글이 상태에는 '본 글'로 남아 매거진에서 영영 빠짐 | 잠금 기다림(뒤 스레드 3초 · 메인 0.1초 — busy handler), 못 넣은 글은 `Editor.retry` 에 두었다가 다음 받아 넣기 때 먼저(3000건까지), 한 번 실패하면 나머지는 바로 미룸. 사진 주소·점수 쓰기는 Editor 로(메인이 잠금을 기다리지 않게) | `failedIngestIsRetried`·`shortLockIsWaitedOut`·`mainThreadWriteDoesNotWaitLong`, F4·F5 |
| S8 | 매거진을 열 때 분야 사진(`SectionPhotos.load`)이 메인에서 3000건을 읽고 낱말 분류, 스토리 카드마다 보도 전부를 메인에서 분류 — 한국어 낱말 찾기(`contains`)가 유니코드 동치까지 따져 느림 | 분류·읽기를 화면 줄기 밖으로, 스토리 분야는 목록 만들 때 미리(`StoryCard.topic`), 한국어 낱말은 NFC 로 맞춘 뒤 글자 그대로(`.literal`, 6.6배 빠름 · 결과 같음) | `decomposedHangulStillMatches`, startup 측정(스토리 9~19초 → 0.2~0.6초) |

시험 장치 쪽 손질: `E2EFeeds.serve` 를 async 로(느린 출처 흉내), 고장 흉내(`setFault`), 견본 글은 출처마다 60건·견본 사진은 색 36가지만 기억(오래 켜 두기에서 견본이 끝없이 쌓이지 않게).

업데이트 안전: 자료 형식·경로는 바꾸지 않았다(DB 표·상태 파일 그대로). 되돌려도 예전 판이 그대로 읽는다.

## 남은 것(다음에 이어 할 순서)

1. **고친 뒤 오래 켜 두기 다시 재기** — `SOAK_DAYS=4 SOAK_STEP_MIN=15 SOAK_POSTS=60 soak.sh` (약 40분). 오늘은 무거운 작업 대기열이 차서 못 돌림. 확인 평균(4.5초)·메인 최장(1.2초)·스토리 목록이 줄었는지, footprint 가 400MB 아래에서 머무는지.
2. **시나리오 e2e(`scripts/e2e/run.sh`)를 이 변경으로 다시 돌리기** — 오늘 못 돌림(swift test 345개는 통과).
3. **윈도우·리눅스 고치기** — 읽기 전용 점검 결과(2026-10-16, 고치지 않음). 고친 뒤 dotnet test·`windows/scripts/check-on-mac.sh`·cargo test.

   | | 윈도우(C#) | 리눅스(Rust) |
   |---|---|---|
   | S1 사진 캐시 | 장 수(160)만 — `Dropcap.Ui/ImageLoader.cs:61`. 담는 것은 JPEG 이라 맥보다 작음. `Shrink`(:104)가 원본(최대 40MP)을 다 풀고 줄임 · 같은 주소 경쟁에서 진 그림을 Dispose 안 함 | **같음** — `dropcap-gtk/src/widgets.rs:103-121` 텍스처 160장(1400px RGBA 최대 ~1.2GB) + 카드마다 Cairo 표면 사본(`menu.rs:703,744`), 분야 사진 표면은 지우지 않음(`section_photos.rs:143-163`) |
   | S2 피드 전체 시간 | 안전 — `SafeHttp.cs:144` CancelAfter 가 본문 읽기까지 | 안전 — reqwest `.timeout(20s)`(`net.rs:90`). 리다이렉트마다 20초라 최대 ~220초, `check_all` 전체 상한 없음 |
   | S3 번역 | **같음** — 요청 15초, 묶음 실패 뒤 문단마다(40개) 다시 · 쉬기 없음(`Translator.cs:206-223`) | **같음** — `translator.rs:216-221` |
   | S4 잠시 끄기 | **같음** — `AppModel.cs:635` | **같음** — `app_model.rs:813-815, 472` |
   | S5 스토리 목록 | 스토리마다 두 번(`Magazine.cs:532`·`MagazinePage.cs:309`) — 뒤 스레드라 화면은 덜 멈춤. 뒤 스레드에서 State 사전을 읽음(스레드 안전 위험) | 같은 N+1(`magazine.rs:566-572`·`magazine_pages.rs:84-89`) — tokio 위, GTK 스레드 아님 |
   | S6 낱말 찾기 | 안전(Ordinal). `NewsItem.Category` 캐시 없음(`Models.cs:113`) | 안전(Rust contains) |
   | S7 DB 쓰기 실패 | **같음(글 잃음)** — `Upsert` 예외가 `Ingest` 를 끊고 이미 Seen 에 남음(`AppModel.cs:516`·`Magazine.cs:119-130`) | **같음(글 잃음)** — `database.rs:169-175` 오류를 버림, seen 은 먼저(`app_model.rs:200`) |
   | S8 분야 사진 | 분야마다 3000건 읽기(11번, `PhotoScorer.cs:67`) — 뒤 스레드 | 같음(`section_photos.rs:49-50`) — 뒤 스레드 |
   | storySeen | 지우지 않음 | 지우지 않음(`store.rs:201`) |

4. 작은 것(측정상 영향 작음, 고치지 않음):
   - `ArticleService`(Reader/ — 다른 작업자 담당): `cached()` 가 디스크에서 읽은 기사를 메모리에 넣을 때 순서 목록에 안 넣어 40개 상한 밖으로 천천히 늘어남 · `listeners[link]` 빈 사전이 남음.
   - `AppState.storySeen`: 본 스토리마다 한 줄, 지우지 않음(DB 에서 지운 스토리 것도). 한 줄 수십 바이트라 1년에 수백 KB.
   - `Magazine.digestCache`: 스토리 요약을 지우지 않음(연 스토리 수만큼).
   - 느린 출처 하나가 확인 전체를 그만큼 늦춤(F3: 25초) — 상한 60초 안. 늦은 출처를 다음 확인으로 미루는 것은 설계 변경이라 하지 않음.
   - 스토리 상세(`StoryDetail`)는 아직 메인에서 그 스토리 보도를 읽음(보도가 아주 많은 스토리면 느릴 수 있음).
5. 주의: 다른 작업자(Design)가 UI 값 토큰화 중 — `UI/MagazineView.swift`(StoriesView·StoryListCard)·`UI/SectionPhotos.swift`·`UI/RemoteImage.swift` 는 이 가지를 먼저 합친 뒤에 손대기로 함.
