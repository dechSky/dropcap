# 맥 앱 버그 점검 (mac-audit)

> 상태: 반영됨(2026-10-13 점검 · 2026-10-14 6절까지). 물병 관련 항목은 '물병 제거로 무효' 그대로. 이후 바뀜 — 2차에서 넣은 받는 크기 상한이 2xx 아닌 응답을 'IP 확인 안 됨'으로 바꾸던 회귀는 READSWEEP 에서 고침(9601e8d).

- 범위: `mac/Sources/Dropcap/{Core,Toast,Reader,UI}`, `mac/Tests`, `mac/scripts`. 기준 문서 `docs/FEATURES.md`.
- 방법: 모든 소스를 읽고 기능 번호(C·S·T·N·R·M·U·P·K·H·D·Q)별로 대조. 의심 가는 곳은 작은 시험·스크립트로 재현했다.
- 조치: **고침** = 이 브랜치에서 고치고 `mac/Tests/DropcapTests/AuditTests.swift` 에 시험을 더함. **제안** = 고치지 않고 기록만(구조 변경이 크거나, 고치지 말라고 한 파일).
- 추가 안내 1(물병 제거·상단바 머리/목록 변경): 물병 관련 파일·부분(Knowledge·VesselView·World3D·ScaleWorld·WorldArt·WorldThumb·VesselPage·drops 기록)과 MenuView 머리·목록은 점검·수정에서 뺐다. 해당 항목은 '물병 제거로 무효' 로 표시.
- 고치지 않기로 한 파일: `Core/Category.swift` · `shared/sources.json` · `Core/Channels.swift` · `UI/SettingsView.swift` (매거진 전환 작업과 충돌 방지). 이 파일의 버그는 아래 표에 **제안**으로만 적었다.
- 심각도: 치명(앱이 죽거나 기록을 잃음, 흔히 생김) · 높음(앱이 죽거나 기록을 잃음, 드물게 생김 / 기능이 크게 틀어짐) · 중간(기능 일부가 틀리거나 자원을 계속 낭비) · 낮음(드물거나 겉모습·미세한 낭비).

## 1. 발견 목록

| 번호 | 심각도 | 파일:줄 | 증상(재현 방법) | 원인 | 조치 |
|---|---|---|---|---|---|
| A-01 | 높음 | Core/Channels.swift:164 | 구독 칸에 공개 IPv6 주소(예: `https://[2606:4700:4700::1111]/blog`)를 넣으면, 피드·`<link rel=alternate>` 를 못 찾은 뒤 앱이 죽는다 | `url.host` 는 IPv6 를 괄호 없이 돌려주는데 `URL(string: "https://\(host)")!` 로 강제 언랩 → nil → 충돌. 스크립트로 `URL(string:"https://2606:4700:4700::1111")` 이 nil 임을 확인 | 제안(손대지 말 파일): `URLComponents` 로 scheme·host(IPv6 면 `[...]`)·port 를 넣어 만들고 nil 이면 `Failure.notFound` |
| A-02 | 높음 | Core/Database.swift:19 | `magazine.sqlite` 가 깨지거나 SQLite 파일이 아니면(디스크 오류·다른 프로그램이 덮어씀) 매거진이 영영 비고, **새 스크랩·호가 조용히 저장되지 않는다** | `sqlite3_open` 은 깨진 파일도 성공으로 연다. '옆으로 치우고 새로 만들기'는 open 실패에만 걸려 실제로는 한 번도 돌지 않았다 | **고침**: 첫 문장(스키마 만들기)이 `SQLITE_NOTADB/CORRUPT` 면 본 파일·`-wal`·`-shm` 을 `magazine.broken.sqlite*` 로 치우고 새로 만든다(그 밖의 오류는 건드리지 않음). 시험 `DatabaseRecoveryTests` |
| A-03 | 높음 | Core/Store.swift:126 | `native-state.json` 이 통째로 깨지면(잘린 파일 등) 구독·저장·읽음·물병이 모두 초기화된다. 다음 실행 첫 저장 때 깨진 파일이 `.bak` 을 덮어 **되살릴 길도 사라진다** | 읽기 실패 시 `.bak` 을 보지 않고 `AppState()` 로 시작, 첫 저장 때 무조건 `본 파일 → .bak` 복사 | **고침**: 본 파일을 못 읽으면 `.broken.json` 으로 남기고 `.bak` 에서 읽음. 그 실행에서는 `.bak` 을 덮어쓰지 않음. 시험 `StateRecoveryTests` |
| A-04 | 중간 | Core/Translator.swift:36 | 오래 켜 두면 번역 캐시가 끝없이 커진다(T-03 "4000개 넘으면 비움" 위반) | 상한 검사가 `translate()`(요약 한 줄)에만 있고, 본문·제목 번역이 모두 지나는 `translateMany()` 에는 없음 | **고침**: 캐시 쓰기를 `remember()` 한 곳으로 모으고 거기서 4000 상한. 시험 `TranslatorCacheTests` |
| A-05 | 중간 | Core/Magazine.swift:121 | 사진 없는 최근 기사 가운데 **최신 12건이 og:image 가 없는 곳**이면, 확인할 때마다(기본 5분) 같은 12곳을 다시 받고 그 뒤 기사들은 사진을 영영 못 채운다(M-13) | 실패한 기사를 기억하지 않아 `prefix(12)` 가 늘 같은 기사를 고름 | **고침**: 이번 실행에서 찾아본 기사는 건너뜀(최대 5000개 기억). 시험 `EnrichPickTests` |
| A-06 | 중간 | Core/FeedParser.swift:158 | 제목·요약에 `&rsquo;` `&ldquo;` `&hellip;` `&#x2019;` 같은 표기가 그대로 보인다. `&amp;lt;` 는 실행마다 `&lt;` 또는 `<` 로 다르게 풀린다(C-02) | 15개 고정 문자열만 바꿨고, 사전(Dictionary) 순서대로 차례로 바꿔 두 번 풀리기도 함 | **고침**: 정규식 한 번 훑기로 숫자 표기 전부 + 흔한 이름 표기를 풀고, 이미 푼 결과는 다시 풀지 않음. 시험 `EntityDecodeTests` |
| A-07 | 중간 | Reader/ImageTools.swift:94 | 사진 속 글자 번역에서 Vision 이 실패하면 앱이 멈출 수 있다(가능성) | 완료 처리기와 `perform` 의 throw 양쪽에서 같은 continuation 을 resume → 두 번이면 치명 오류 | **고침**(방어): 한 번만 resume 하는 `ResumeOnce`. 실제 실패를 만들 그림을 찾지 못해 시험은 없음 |
| A-08 | 중간 | Core/Category.swift:42 | 분류가 엉뚱하다: "The **impact** of AI…"→정책("act "), "…in **capital**…"·"**rapid**"→모델("api"), "a **flaw**…"→정책("law"), "**ideal**…"→투자("deal"), "**urban** …"→정책("ban "), "**happen**"→모델("app") | 낱말 경계 없이 `contains` 로 부분 문자열을 찾음 | 제안(손대지 말 파일): 영어 규칙은 `\b` 낱말 경계 정규식으로, 한국어는 지금처럼 부분 일치. 세 앱이 같은 규칙을 쓰므로 함께 바꿔야 함 |
| A-09 | 중간 | Core/Magazine.swift:77, 157 · Core/AppModel.swift:132 · UI/MagazineView.swift(SearchView·SavedView) | 매거진을 열어 두면 확인 때마다·지면 전환 때마다 잠깐씩 멈칫한다(Q-07 은 ✓ 로 표시돼 있음) | `Magazine`·`AppModel` 이 `@MainActor` 이고 그 안에서 DB(`queue.sync`)·JSON 해독·문장 임베딩을 모두 화면 줄기에서 한다: `ingest` 는 7일 치 스토리마다 DB 질의 + 임베딩 비교, `makeIssue` 는 최대 4800건 JSON 해독(오늘·이번 주 화면을 그릴 때마다, `publishDue` 는 확인마다 4호), `groupSameStory` 임베딩, 검색 LIKE+json_extract, 저장 지면은 본문 캐시 파일을 그릴 때마다 읽음 | 제안(리팩토링 절 R-1) |
| A-10 | 중간 | Core/FeedService.swift:48 · UI/RemoteImage.swift:39 | 악의적·고장 난 피드나 사진 주소가 아주 큰 응답(수백 MB~GB)을 보내면 전부 메모리에 받은 뒤에야 버린다(사진 8MB 상한도 다 받은 뒤 검사) | `URLSession.data(for:)` 가 본문 전체를 모음. 크기 상한 없음 | 제안(리팩토링 절 R-2): `bytes(for:)` 로 받으며 상한(피드 10MB·사진 8MB·페이지 2MB) 넘으면 끊기 |
| ~~A-11~~ | — (물병 제거로 무효) | UI/ScaleWorld.swift:88 | '나의 물병' 지면을 열어 두면 가만히 있어도 화면 주사율(최대 120Hz)로 계속 다시 그리고, 매 프레임 상태를 바꿔 SwiftUI 본문까지 다시 계산한다. 움직임 줄이기도 무시 | `TimelineView(.animation)` 간격 제한 없음 + Canvas 안에서 `DispatchQueue.main.async { lastZ = …; lastT = … }` 로 매 프레임 @State 변경 | 제안: 움직이는 중(드래그·이동·불꽃)이 아니면 `.animation(minimumInterval: 1/20)`, 움직임 줄이기면 정지 그림. `lastZ/lastT` 는 참조형 상자에 담아 @State 변경을 없앰 |
| A-12 | 낮음 | Core/URLSafety.swift:104 | `http://[fec0::1]/` 같은 IPv6 사이트 로컬 주소를 공개 주소로 본다(S-01) | fec0::/10 검사 없음(폐지된 범위지만 사내망에 남아 있음) | **고침**. 시험 `SiteLocalIPv6Tests` |
| A-13 | 낮음 | Core/Store.swift:148 · AppModel | 오래 켜 두면 메모리의 '본 글 기억'이 끝없이 늘고, 8000개를 넘은 뒤로는 저장할 때마다 전체를 정렬한다(기사 하나 열면 저장 4번) | 정리를 저장 파일 사본에만 했음 | **고침**: `Store.pruned` 로 확인 끝에 메모리도 정리(저장 결과는 같음). 시험 `seenIsPrunedOldestFirst` |
| A-14 | 낮음 | Reader/ArticleService.swift:67 | 미리 받기가 스크립트 없이 실패한 기사를 사용자가 열면, 다시 시작한 작업의 '진행 중' 표시가 지워져 같은 기사를 두 번 추출할 수 있다 | 끝난 작업이 `inflight[link] = nil` 을 무조건 실행 → 새 작업 항목까지 지움 | **고침**: 자기 작업일 때만 지움. 네트워크·웹 보기가 필요해 단위 시험은 없음 |
| A-15 | 낮음 | Reader/ReaderView.swift:54 | 주소에 공백·한글(퍼센트 인코딩)이 든 기사는 실패 화면에서 '번역된 웹페이지로 보기' 단추가 사라진다(R-12) | `URL.path` 가 인코딩을 풀어 돌려줘 새 주소가 nil | **고침**: `path(percentEncoded: true)`·`query(percentEncoded: true)`. 시험 `TranslatedPageTests` |
| A-16 | 낮음 | UI/MenuView.swift:113 | 다른 출처가 같은 id(guid 없이 같은 주소 등)를 쓰면 상단바 목록 줄이 섞여 그려지거나 SwiftUI 경고가 난다 | `ForEach` 의 id 를 출처 안에서만 고유한 `id` 로 씀 | 제안(추가 안내 1: main 에서 목록 모양이 바뀌어 충돌 방지로 고침을 되돌림): 새 목록에서 `id: \.element.key` 로 |
| A-17 | 낮음 | UI/MagazineView.swift:356 | 움직임 줄이기를 켜도 표지 사진이 22초 왕복으로 계속 움직인다(N-17·접근성) | 켄 번스에 `accessibilityReduceMotion` 검사 없음 | **고침**: 움직임 줄이기면 시작하지 않음 |
| A-18 | 낮음 | Core/Channels.swift:112, 114 | `notyoutube.com` 같은 이름도 YouTube 로 처리, 재생목록 id 를 인코딩 없이 주소에 넣음, 흔한 위치 찾기에서 포트가 빠짐 | `hasSuffix("youtube.com")`, 문자열 붙이기 | 제안(손대지 말 파일): `host == "youtube.com" \|\| host.hasSuffix(".youtube.com")`, `URLComponents` 로 조립 |
| A-19 | 낮음 | UI/SettingsView.swift:181 | 거르기 낱말을 적고 Return·저장을 누르지 않은 채 탭을 옮기거나 창을 닫으면 사라진다 | `onSubmit`·저장 단추에서만 저장 | 제안(손대지 말 파일): `onChange(of:)` 나 `onDisappear` 에서도 저장 |
| A-20 | 낮음 | Core/AppModel.swift:334 | '아침 브리핑'이 브리핑 시각 이후라면 그날 언제든(예: 밤 10시에 처음 켬) 뜬다 | 조건이 `hour >= digestHour` 뿐 | 제안: 정한 시각 + 몇 시간(예: 정오) 안에만, 또는 '그날 첫 실행이 오후면 건너뜀'. 의도된 동작이면 FEATURES 에 적기 |
| A-21 | 낮음 | Core/Magazine.swift:217 | 정오 전에는 확인할 때마다 어제 호를 다시 엮고, `archive` 를 늘 새 배열로 바꿔 매거진 옆 목록이 확인마다 다시 그려진다 | `refresh` 때 무조건 저장, 저장마다 `Issue.date = Date()` 라 내용이 같아도 다름 | 제안: 기사 key 목록이 같으면 저장·대입 생략 |
| A-22 | 낮음 | Core/FeedService.swift:194 · Reader/ArticleExtractor.swift:178 | 측정값·로드 완료를 기다리는 `withTaskGroup` 이, 시간 초과 순간에 continuation 이 아직 등록 전이면 끝없이 기다릴 수 있다(극히 드묾) | 시간 초과 쪽이 먼저 끝나면 `takeWaiter()` 가 nil, 이후 등록된 continuation 은 아무도 깨우지 않음 | 제안: 등록 전에 '끝남' 표시를 보고 바로 resume 하도록 상태값 하나 추가 |
| A-23 | 낮음 | Reader/ArticleService.swift:96 | 미리 받기 실패 뒤 같은 기사를 다시 준비하면 메모리 LRU 목록에 같은 주소가 두 번 들어가, 최근 기사가 일찍 밀려난다 | `memory` 만 지우고 `order` 는 남김 | 제안: `order.removeAll { $0 == link }` |
| A-24 | 낮음 | Core/Translator.swift:13 · ArticleService:130 | 읽기 창의 '번역 방식'(기기 내/Google)이 틀리게 보일 수 있다(캐시로 끝났거나 다른 번역이 동시에 돌면) | `lastEngine` 이 앱 전체에 하나 | 제안: `translateMany` 가 쓴 엔진을 함께 돌려주기 |
| A-25 | 낮음 | Core/Translator.swift:112 | 4500자 넘는 한 문단은 뒤가 잘린 채 번역된다 | `text.prefix(4500)` | 제안: 문장 단위로 쪼개 보냄 |
| A-26 | 낮음 | UI/RemoteImage.swift:38 | 디스크 사진 캐시를 다시 써도 수정 시각이 안 바뀌어, 자주 보는 사진부터 지워질 수 있다 | 정리가 '쓴 순서'만 봄 | 제안: 읽을 때 수정 시각 갱신(ArticleService 처럼) |
| A-27 | 낮음 | Toast/ToastCenter.swift:139 | 화면이 하나도 없을 때(덮개 닫고 외부 화면 없음, 깨어나는 순간) 알림이 오면 앱이 죽을 수 있다 | `NSScreen.screens[0]` | 제안: 화면이 없으면 알림을 미루거나 건너뜀 |
| A-28 | 낮음 | Toast/ToastView.swift:171 | 알림 카드의 '나중에 읽기' 단추를 눌러도 아이콘이 바로 채워지지 않을 수 있다 | 카드가 `AppModel` 을 관찰하지 않음(다른 이유로 다시 그려질 때만 바뀜) | 제안: 카드 안 `@State` 로 저장 여부를 들고 누를 때 바꿈 |
| A-29 | 낮음 | Core/HotKey.swift:30 | ⌥⌘N/⌥⌘M 을 다른 앱이 먼저 쓰고 있으면 조용히 안 된다 | `RegisterEventHotKey` 결과를 보지 않음 | 제안: 실패를 기록하고 설정 단축키 절에 표시 |
| A-30 | 낮음 | Core/Scrapbook.swift:94 | 제목에 `]`, 주소에 `)` 가 있으면 내보낸 Markdown 링크가 깨진다(M-18) | 이스케이프 없음 | 제안: `]`→`\]`, 주소는 `<...>` 로 감쌈(세 앱 형식이 같아야 하므로 함께) |
| A-31 | 낮음 | Core/FeedParser.swift:103 | guid·link 가 모두 빈 글은 key 가 `출처\|` 로 겹쳐 하나만 남는다 | id 가 빈 문자열 | 제안: 제목+날짜 해시로 대신 |
| A-32 | 낮음 | Core/Store.swift:103 | 이름 바꾸기 전 폴더에서 옮기다 중간에 실패하면 다시 시도하지 않는다 | 새 폴더가 생긴 뒤라 다음 실행에서 조건(`!exists(d)`)이 거짓 | 제안: 다 옮긴 뒤에 표시 파일을 쓰고 그걸로 판단 |
| A-33 | 낮음 | Core/Database.swift:58 | DB 쓰기가 잠김·디스크 가득 등으로 실패해도 기록이 남지 않는다 | `sqlite3_step` 결과가 DONE/ROW 가 아니면 그냥 멈춤 | 제안: 오류면 `NSLog` |
| A-34 | 낮음 | Core/Summarizer.swift:12 | Apple Intelligence 가 꺼진 Mac 에서는 기사마다·설정 화면을 그릴 때마다 같은 로그가 쌓인다 | `available` 이 부를 때마다 NSLog | 제안: 한 번만 기록 |
| A-35 | 낮음 | Reader/ImageTools.swift:272 | 닫은 사진 번역 창이 다음 창을 열 때까지 사진째 메모리에 남는다 | 닫힘 알림 대신 다음 열기 때 정리 | 제안: `willClose` 에서 빼기(ReaderController 처럼) |
| A-36 | 낮음 | UI/MenuView.swift:15 · Reader/ReaderView.swift:243 · ImageKey | 화면을 그릴 때마다 같은 계산을 되풀이(목록을 3번 거르고 정렬·중요순이면 DB 질의, 읽는 시간은 본문 전체를 매번 합침, 사진 key 정규식을 매번 컴파일) | 계산 속성 | 제안: 한 번 계산해 지역 변수로, 정규식은 static |
| A-37 | 낮음 | Reader/ReaderView.swift:164 | 주소가 이상한 기사의 '공유'는 example.com 을 공유한다 | 대체 주소 | 제안: 주소가 없으면 공유 단추를 숨김 |

## 2. 기능별로 확인한 것(문제 없음)

- C-08·C-09·C-11·C-12·C-19·C-20·C-22·C-23·C-25: 코드가 문서 수치와 같음(3일, 8000, 300, 3000→2000, 방해 금지 자정 넘김, 간격 바꿔도 진행 중 확인은 별도 작업으로 끝까지).
- S-01~S-05·S-08·S-09·S-11: 숫자 꼼수·IPv4 매핑·NAT64·6to4·리디렉션·웹 보기 이동 검사, 실패 시 막음(fail closed), gzip 32MB 상한 확인. (A-12 하나만 추가)
- N-07·N-10·N-13·N-14·N-17: 머무름 9초·마우스 올림 마감 미룸·4장·0.32초·카드 밖 클릭 통과·초점 안 뺏음·움직임 줄이기 분기 확인. 알림 패널의 30Hz 마우스 타이머는 알림이 다 사라지면 멈춤.
- R-02·R-15·R-16: 느린 길 0.6초/0.4초/15초, 메모리 40·디스크 150(저장 기사 제외), 상위 3건 미리 받기.
- M-05·M-10·M-11·M-16·M-20: 지난 호 3일+주간, 정렬 기억, 새 소식 띠, 2글자 검색, 단축키.

## 3. 리팩토링 제안(이번엔 손대지 않음)

- **R-1 매거진·편집 작업을 화면 줄기 밖으로** (A-09): `Magazine` 의 `ingest`·`makeIssue`·`publishDue`·`search` 를 별도 actor(예: `Editor`)로 옮기고 결과(`Resolved`)만 메인으로 넘긴다. `AppModel.groupSameStory` 의 임베딩 비교도 스냅숏을 넘겨 뒤에서 계산. `ingest` 의 '스토리마다 대표 기사' N번 질의는 한 번의 SQL(스토리별 최신 1건)로. 매거진 전환 작업과 겹치므로 그 뒤에 하는 것이 안전.
- **R-2 받는 크기 상한** (A-10): `FeedService.fetchOnce` 를 `session.bytes(for:)` 로 바꾸고 종류별 상한. `ImageLoader` 는 그 상한을 그대로 씀.
- **R-3 저장 묶기**: 기사 하나 열 때 `markRead`·`setRead`·`noteInterest`·`addDrop` 이 각각 `Store.save`(전체 JSON 인코딩·원자적 쓰기)를 부른다. 0.5초 묶어 한 번 쓰고, 끝낼 때(`applicationWillTerminate`) 바로 쓰기.
- **R-4 같은 소식 판단 한 곳으로**: 알림 묶기(`AppModel.groupSameStory`)와 매거진 스토리(`Magazine.ingest`)가 비슷하지만 다른 규칙(대표 비교 vs 36시간 recent 비교)을 따로 갖고 있다. 다른 두 앱도 같이 옮겨야 하므로 한 함수·한 시험 묶음으로.
- ~~R-5 ScaleWorld 그리기 갱신~~ — 물병 제거로 무효.
- **R-6 분류·채널 해석 시험 더하기**: A-08·A-01·A-18 을 고칠 때 `Category`·`ChannelResolver` 에 경계 사례 시험(낱말 경계, IPv6, 포트, 유사 도메인)을 함께 넣기.

## 4. 실행 확인(시험 폴더 `DROPCAP_DATA_DIR`, 실제 기록은 건드리지 않음)

- 잘린 `native-state.json`(unread 2) + 정상 `.bak`(unread 7) + SQLite 가 아닌 `magazine.sqlite` 로 디버그 빌드를 띄움:
  - 로그 `[상태] native-state.json 이 깨져 .bak 에서 되살렸습니다` → 본 파일 unread 7 로 복구, `.bak` 은 그대로(덮이지 않음), 깨진 파일은 `native-state.broken.json` 으로 남음.
  - 로그 `[DB] 열기 실패, 새로 만듭니다: file is not a database` → `magazine.broken.sqlite` 로 치우고 새 DB 에 `[매거진] 첫 호를 40건으로 채웠습니다`.
- `DROPCAP_TEST_TOAST` 스냅숏(1.3~3.4초): 물방울 → 카드, 글자 떠오름 정상. 알림이 사라진 뒤(25초) CPU 0.0%.
- `swift test`: 51개(23묶음) 모두 통과. 이 가운데 새 시험 13개(`AuditTests.swift`).

## 5. 후속 처리(wt/perf-keys)

- **R-1·A-09 고침**: 매거진 엮기·스토리 배정·지난 호 발행·검색·알림용 스토리/보도 수를 `Core/Editor.swift`(actor)로, 알림 목록의 같은 소식 비교는 뒤 작업으로. 스토리 대표는 SQL 한 번(`Database.representatives`). 전후 수치는 `mac/PERF-KEYS.md`.
- **R-3 고침**: `StateSaver` — 0.5초 묶기, 뒤 스레드 쓰기, 끝낼 때·잠들기 전 즉시. A-03(손상 시 .bak 보존) 유지·시험.
- **R-4 고침**: `Core/StoryGrouper.swift` 한 곳(알림 목록 묶기·매거진 스토리 배정). 기준은 그대로(시험 `StoryGrouperTests`).
- **A-20·A-21·A-23·A-26·A-27·A-28·A-29·A-33·A-34·A-35 고침**. A-37 은 읽기 창 작업(C)에서 이미 고침.
- **A-36 일부**: 상단바 목록의 같은 그리기 코드 두 벌을 하나로 합침. 그릴 때마다 다시 거르는 계산은 그대로.

## 6. 후속 처리(wt/extras 2차)

- **R-2·A-10 고침**: `FeedService.fetchOnce` 를 `URLSession.bytes(for:)` 로, 종류별 상한(`FetchLimit` 피드 10MB·페이지 2MB·사진 8MB)을 넘으면 받는 도중 끊음. `ImageLoader` 도 같은 상한. 내 Mac 안 시험 서버로 확인(`FetchLimitTests`).
- **A-22 고침**: `RequestGuard` 는 시간 초과로 기다리기를 끝내면 표시해 두고 늦게 등록된 기다림을 바로 깨움. `ArticleExtractor.waitForLoad` 도 '이번 로드 끝남' 표시로 같은 문제를 막음.
- **A-24 고침**: `Translator.translateManyReporting` 이 이번 번역에 쓴 엔진을 돌려줌(캐시에 엔진도 함께 기억). 읽기 창은 그 값을 씀.
- **A-25 고침**: 4500자 넘는 문단은 문장 단위로 나눠 보내고 이어 붙임(`Translator.sentenceChunks`).
- **A-31 고침**: guid·link 가 모두 빈 글은 제목+날짜로 만든 고정 id(`noid-…`).
- **A-32 고침**: 예전 폴더 옮기기 중 `.migrating` 표시를 두고, 실패하면 다음 실행에서 빠진 것만 다시 옮김(덮어쓰지 않음). 이미 옮긴 폴더는 건드리지 않음.
- **A-37**: 이미 고쳐져 있음(읽기 창이 공개 http(s) 주소일 때만 공유 단추를 보임) — 표시만.

## 7. 보안 점검 낮음 등급(wt/security-low · 2026-10-15)

항목마다 고치기 전 실패하는 시험을 먼저 두고(`SecurityLowTests`), 고친 뒤 통과를 확인했다.

- **M7 받아들인 위험 — 프록시를 거친 응답**: 시스템 프록시를 거친 연결은 접속 IP 가 프록시 것이라 볼 수 없어, 예전처럼 연결 전 이름 확인(`URLSafety.resolvesPublic` — 요청과 리다이렉트마다 공개 대역인지)에만 맡긴다. 설정된 프록시가 없는데 프록시 연결이면 막는 것도 그대로. 판정만 `RequestGuard.judge` 순수 함수로 떼어 시험(`proxiedHopJudgedByNameCheckOnly`).
  - 남은 위험: 프록시가 이름을 다시 풀면(확인 뒤 DNS 응답을 바꾸는 공격) 요청이 프록시 쪽 내부망으로 갈 수 있다. 응답 내용은 피드·기사·사진으로만 쓰이고, 공격자가 이름 확인 시점을 맞춰야 한다.
  - 받아들인 까닭: 막으려고 '출처 피드 도메인만 받기'를 해 보니(1차 커밋) 회사 Mac 처럼 프록시를 쓰는 사용자의 사진 CDN(다른 도메인)·기사 빠른 길(출처 밖 링크)·새 채널 찾기·번역 요청이 모두 막혔다. 낮음 등급 위험에 비해 정상 기능 손실이 커서 되돌림. 미리 푼 IP 로 직접 붙는 길은 URLSession 의 TLS 이름 확인(SNI·인증서) 때문에 쓸 수 없다. 리눅스·윈도우의 프록시 처리도 같은 방향(연결 전 이름 확인)으로 맞춘다.
- **M8 고침 — 느린 길 WKWebView**: content rule 에 내부망·내 Mac 주소 규칙을 더함(127/8 · 10/8 · 0/8 · 192.168/16 · 169.254/16 · 172.16/12 · 100.64/10 · localhost · *.localhost · *.local · [::] · [::1] · fc00::/7 · fe80::/10 · ::ffff:). 종류와 상관없이 막아 페이지 스크립트의 fetch·XHR 도 나가지 못함. WebKit 규칙 정규식은 `|` 를 못 써서 하나씩. 컴파일한 규칙은 id 로 디스크에 남으므로 id 를 `ainews-fast-2`·`ainews-full-2` 로 올림. 규칙이 실제로 컴파일되는지도 시험.
- **M9 고침 — 시험 장치를 배포 빌드에서 뺌**: `E2E/*` · `ReaderSaveTestHooks` · `ExtrasTestHooks` · `ReadSweep` · `PerfHarness` · `SectionIconLab` · `SectionCardLab.render` · 위젯 시험 훅과 App.swift 의 시험 블록을 `#if DEBUG` 로 감쌈. 흩어진 `DROPCAP_TEST_*` 읽기도 `#if DEBUG` 또는 `TestEnv.get`(배포 빌드는 늘 nil)으로. `DROPCAP_TEST_SCHEME`(dropcap://save 확인 창 건너뛰기)·`FeedService(allowLocalForTests:)` 도 디버그 빌드에만 있음. 배포 빌드에는 `E2EFeeds` 자리만 '꺼짐'으로 남김(`E2E/E2EOff.swift`).
  - e2e·clicksweep·문서의 시험은 모두 `.build/debug/Dropcap`(swift build) 을 쓰므로 그대로 돈다. `swift test` 도 디버그 빌드.
  - 확인: `scripts/check-release-hooks.sh` — release 로 빌드해 실행 파일에 `DROPCAP_TEST_`·시험 훅 이름이 하나도 없는지 본다. 디버그 실행 파일을 주면 실패(고치기 전 상태와 같음).
  - 그대로 둔 것: `DROPCAP_DATA_DIR`(데이터 폴더 바꾸기 — 바꿔도 다른 폴더에 쓸 뿐)·`DROPCAP_DEBUG_EXTRACT`·`DROPCAP_DEBUG_DRIP`(진단 로그·색)는 시험 장치가 아니라 남김.
- **M10 고침 — 단축어 저장**: `IntentLogic.savableURL` 이 `SaveLink.normalize` 를 그대로 씀. 아이디·암호가 든 주소를 거르고, 조각(#…)·꺾쇠·따옴표 정리도 서비스 메뉴·dropcap:// 저장과 같아짐.
- **M11 고침 — 사진 압축 폭탄**: `ImageLoader.decode` 가 풀기 전에 머리의 가로·세로를 읽어 4천만 픽셀(약 8000×5000) 또는 한 변 10만을 넘거나 크기를 모르면 풀지 않음. 시험은 진짜로 풀리는 8000×8000 PNG(수십 KB).

## 8. 보안 점검 낮음 등급 나머지(wt/seclow3 · 2026-10-16)

두 점검(2026-10-14 · 2026-10-15)의 낮음·정보 항목 가운데 아직 열린 것을 main(e30f0c6)에서 다시 확인해 정리했다. 이미 닫힌 것: M6·M8~M11(7절), M7(7절 받아들인 위험), M12(설정 › 번역 방식 '번역 안 함' + README '번역과 개인정보'), X3·M13·W10·P1~P3(secfix-2), 윈도우 W4~W8·리눅스 L2~L9(각 PROGRESS).
고친 항목은 고치기 전 실패 → 고친 뒤 통과를 확인했다(맥 `SecurityLow3Tests` · 윈도우 `SecurityLow3Tests` · 리눅스 `security_low3_tests`).

- **X2 고침(세 판) — 여러 덩어리 모으기를 비활성 문서에서**: 모은 상자를 `document.createElement`(살아 있는 문서) 대신 `fresh.createElement`(사본 문서)로 만든다. 살아 있는 문서에 붙인 `<img>` 는 받기·`onerror` 가 돌 수 있었다(지금은 빠른 길 JS 꺼짐·사진 차단·윈도우 CSP 로 막혀 있었음 — 한 겹 방어 복구). 시험은 세 판 추출 스크립트에 살아 있는 문서로 노드를 만드는 호출(`document.createElement`·`importNode`·`adoptNode`·`body.append`·`write`)이 없는지 본다.
- **M15 고침(맥만 — 피드 본문은 맥에만 있음)**: 피드 본문 전문(`feedBody`)은 글 링크가 출처 피드와 같은 사이트일 때만 받는다(`FeedService.sameSite` — 등록 도메인 근사: 마지막 두 마디, `co.kr`·`co.uk` 같은 2단계면 세 마디). `feeds.arstechnica.com` → `arstechnica.com`, `rss.politico.com` → `politico.com` 은 그대로 받고, 남의 링크에 본문을 실은 집계 피드(hnrss 등)의 본문은 버려 사이트 추출이 실패해도 남의 기사처럼 보이지 않는다. 시험: 로컬 피드가 다른 사이트 링크에 1,000자 넘는 본문을 실으면 `feedBody == nil`(고치기 전 본문이 남음).
  - 이 고침 전에 피드 기록 DB 에 들어간 본문(같은 글을 다시 받아도 DB 값이 남음)은 읽기 창에서 다시 거른다(`ArticleService.usableFeedBody` — 출처를 모르면 쓰지 않음, Paywall 작업 병합 뒤 main 을 합쳐 고침). 기본 출처 중 피드와 글 사이트가 다른 BBC(`feeds.bbci.co.uk` → `bbc.co.uk`)·WSJ(dowjones)는 피드에 전문을 싣지 않아 잃는 것이 없다.
- **P4 고침 — 문서의 실제 기사 주소**: `mac/READER-CUT.md` 의 기사 주소 11개를 경로 생략(`theverge.com/…`)으로. 다른 문서(PROGRESS·README 등)에는 실제 기사 주소가 없음을 확인. `docs/research/COMPETITIVE.md` 의 주소는 조사 출처 인용(시험 HTML 과 이어지지 않음)이라 그대로.
- **M14 받아들인 위험 — '일부만' 판정 P×G**: 긴 문단 수 × 본문 글 길이. 2MB 안 최악 수 초(점검 재현 0.47초/2,000문단). secfix-2 의 추출 스크립트 시간 제한(`scriptSeconds` 8초, 윈도우·리눅스도 같은 장치)으로 멈춤까지는 가지 않고, 고치려면 문단마다 찾기를 색인으로 바꿔야 해 판정이 달라질 위험이 이득보다 크다.
- **E2E.md 의 내부 도구 이름(2026-10-14 A 낮음) 받아들임**: 개인정보가 아니고 개발 절차 설명이라 그대로 둔다.

## 9. 점검 review-3 낮음·시험 빈틈(wt/fix-review3 · 2026-10-16)

paywall-early·teaser-ld-port·security-low-3 뒤 점검(높음·중간 0)의 낮음 4건과 시험 빈틈 4건. 고치기 전 실패 → 고친 뒤 통과를 확인했다.

- **S1(맥 — 피드 본문은 맥에만) 공용 호스팅**: `FeedService.siteKey` 가 `substack.com`·`github.io`·`blogspot.com`·`wordpress.com`·`medium.com`·`netlify.app`·`tistory.com` 등(`sharedHosts`, 공용 접미사 목록의 짧은 발췌)은 하위 도메인 하나를 한 사이트로 본다. `a.substack.com` 피드가 `b.substack.com` 글에 실은 본문은 쓰지 않는다.
- **B1(리눅스) 맛보기 판정이 바뀌면 화면 다시 그림**: 앱 핵심이 `UiEvent::Paywall` 을 보내 목록 메뉴·매거진 지면이 다시 그린다(맥 `@Published`·윈도우 `TeasersChanged` 와 같음).
- **B2(윈도우) `PaywallBook.RecordTeaser` 잠금**: 동시에 불러도 메모리 표시가 사라지지 않는다.
- **B3(세 판) 다시 맛보기면 시각 갱신**: 계속 맛보기인 기사가 처음 판정 30일 뒤·2,000건 정리에서 빠지지 않는다. 표시가 그대로면 다시 그리지 않는다.
- **시험 빈틈**: 기사 준비가 부르는 판정 함수(맥 `ArticleService.judgeTeaser`·리눅스 `ArticleService::judge_teaser`)와 읽기 창의 피드 본문 찾기(맥 `ArticleService.feedBody(for:)`)를 시험이 그대로 지난다 · X2 는 글자 검사에 더해 실제로 — 맥 WebKit(세 판 스크립트, 고치기 전 꼴은 받기·onerror 가 일어남을 대조로 확인)·윈도우 Chromium(`extract-runner.mjs` probe) · 화면 갱신 알림 시험(세 판) · 윈도우 ld ±10% 경계값.
