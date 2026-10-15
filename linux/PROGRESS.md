# 리눅스 판 진행 기록

담당: linux · 작업: linux-native · 브랜치 `wt/linux-native` · 폴더 `linux/`

## 1단계 — 핵심(화면 없는 부분) ✓

`dropcap-core` (Rust) — `cargo test -p dropcap-core` 이 이 맥에서 통과.

| 번호 | 상태 | 위치 |
|---|---|---|
| C-01 | ✓ sources.json 을 실행 파일 안에 담음(include_str) | models.rs |
| C-02~C-07 | ✓ RSS·Atom·RDF·사이트맵, 사진, gzip, 조건부 요청(해석 성공 뒤 확정), 재시도 | feed_parser.rs, feed_service.rs |
| C-08~C-11 | ✓ 본 글 기억·첫 출처 조용히·3일·AI 글만·간격(진행 중 확인은 끝까지)·깨면 10초 뒤(벽시계/단조 시계 차이로 감지) | app_model.rs |
| C-12 | ✓ flock 잠금 | system.rs |
| C-13 | ✓ 원자적 쓰기·.bak·항목별 관대한 읽기·DROPCAP_DATA_DIR | store.rs |
| C-14, C-16~C-25 | ✓ | app_model.rs, category.rs |
| C-15 | ~ 낱말 규칙은 맥과 같음. 뜻 비교(맥 NLEmbedding)는 "영어 제목 고유명사 2개 이상 공유 + 적은 쪽의 절반 이상"(윈도우와 같은 기준, 814dddc)으로 대신 — 맥 시험 사례 그대로 통과 | story_match.rs |
| S-01~S-04 | ✓ S-03 은 **접속 순간 검사**: 이름 풀기를 앱이 직접 하고(GuardedResolver) 내부망이면 연결하지 않음 + 받은 뒤 실제 IP 재확인 | url_safety.rs, net.rs |
| S-06, S-07, S-09 | ✓ | article.rs, images.rs, feed_service.rs |
| T-01~T-04 | ✓ | translator.rs |
| T-06 | ✓(핵심) Ollama 127.0.0.1:11434 만, 없으면 None | summarizer.rs |
| M-02~M-05, M-13, M-18 | ✓ 같은 표·JSON, 점수식, 호 엮기, 발행, Markdown(글자 하나까지 시험) | database.rs, magazine.rs, scrapbook.rs |
| K-01~K-04 | ✓(핵심) 37개 목록(맥 실제 수), 주소 해석, 15건 규칙 | channels.rs |
| R-01, R-03, R-04, R-07, R-15 | ✓(핵심) 빠른 길(Rust Readability), 블록, 번역 순서, 캐시 40/150 | article.rs |
| P-05 | ✓(핵심) XDG autostart 파일 | system.rs |
| Q-01, Q-02 | ✓ 맥 시험 사례 이식 + 리눅스 추가, 바깥 서버 시험은 DROPCAP_LIVE_TESTS=1 | tests/ |

## 남은 것

- 2단계: 트레이(ksni)·상단바 창(U)·설정(P)·단축키(H)·자동 실행 화면
- 3단계: 읽기 창(R, WebKitGTK)·알림 창(N, 물방울 포함 — 추가 지시 1)
- 4단계: 매거진(M)·스크랩북 화면·디자인(D)·배포(Q-04 AppImage)

## 막힌 것

없음.

## 2026-10-13 저녁 상태(사용 한도로 중단)

- 끝: 핵심(맥 main 버그 점검분까지 반영, 시험 99개 통과), 셸(트레이·상단바 창·설정·단축키·시스템 알림), 알림(물방울 N-01~N-24), 읽기 창(R, webkit 은 안전 검사 프록시 경유), 아이콘·.desktop·AppImage 스크립트(도구 버전·SHA-256 고정), README, 리눅스 전 기능 형 검사 스크립트.
- 보안 검토 지적 7건 모두 고침(XML 깊이, 리다이렉트 검사, WebKit 하위 요청 → 프록시, 프록시 요청 하나씩, 알림 마크업, 소리 임시 파일, AppImage 공급망).
- 남은 것:
  1. 화면 문구·배치를 맥 main 최신(상단바 머리 "Dropcap", 중요순 점수 by_importance, 읽기 창 바이라인·잡그림 정리 body_cleanup/image_key 사용)에 맞추기 — 핵심 함수는 준비됨
  2. docs/FEATURES.md 리 열 채우기(C-15 는 "~ 기기 내 문장 임베딩 없음 → 고유명사 공유로 대신(맥 시험 사례 동일 결과)")
  3. 매거진(M) 화면: 새 FEATURES 나올 때까지 보류(추가 지시 2)
  4. 결정필요: THIRD_PARTY_NOTICES 에 linux/resources 사본 경로 추가, "N건 더" 카드의 "상단바 아이콘" 문구를 리눅스에서 "트레이"로 바꿀지

## 2026-10-13 밤 — 완료

- 추가 지시 2·3 반영: 분야는 정의 파일에서(categories.json · shared/categories.json), 문구 표(strings.rs·texts.rs), 일반 뉴스 전환 G-01~G-13, 매거진 재개, 물병 제거, 상단바 머리 'Dropcap'·첫 소식 크게.
- docs/FEATURES.md '리' 열 151칸 모두 채움(✓ · ~ 사유 · ⊘ 사유). 리눅스 전용 경로는 "리눅스 확인 필요"로 표시, 확인 목록은 README.
- K-01 문구를 맥 실제 목록 수(37개)로 고침.
- 시험: cargo test 전체 통과(핵심 132 · 화면 6), 맥에서 리눅스 전 기능 형 검사 통과, 이 맥에서 앱 실행·PNG 로 화면 확인.
- 남은 결정필요: THIRD_PARTY_NOTICES 에 리눅스 사본 경로 추가, '상단바 아이콘' 문구를 리눅스에서 '트레이'로 바꿀지.

## 2026-10-14 — 맥 새 기능 따라잡기(추가 지시 4) 완료

- 핵심(dropcap-core): `paywall.rs`(유료 판정 · 배움 · 맛보기 감지 · 무료 보도 고르기, G-14·G-15), `focus_guard.rs`(회의·발표 중 조용히, N-25 — 15초 기억, 시험용 DROPCAP_TEST_FOCUS), `today_issue.rs`(오늘 호 완독, M-23), `brief.rs`(분야별 저녁 정리, N-26 — Ollama), `photo_quality.rs`(분야 대표 사진 점수·표지 고르기, M-24), DB 표 `extract_stats`·`image_scores`(맥과 같은 열), 상태 `briefs`·설정 `autoQuiet*`·prefs `todayIssueDone`(예전 파일은 기본값으로 읽음). 방해 금지·잠시 끄기와 같은 길 `is_hushed`(확인·묶음·팔로우 스토리·아침 브리핑).
- 읽기: 짧은 글 추출(100자 기준 · 본문 영역 대체 · 맨 글자 줄 나누기 · 글 있는 페이지는 느린 길 건너뜀 · 401/403/429 는 6초만 시도하고 그 실행 동안 막힌 곳으로) — Rust 판·WebKit 스크립트 둘 다. 실패 화면은 피드 요약 + 막힌 사이트 문구 + '원문 열기' 먼저(번역 페이지는 외국어일 때만), 불러오는 동안 피드 요약 먼저.
- 화면(dropcap-gtk): `keynav.rs`(H-03~H-05 — 목록·매거진 카드 ↓/J·↑/K·Enter·S·O·M, 강조 테두리·가운데 스크롤, Ctrl+[ ·], 읽기 창 J·K 같은 창에서·Esc), `section_photos.rs`(분야 유리 카드 + 오늘의 사진 — 분야 고르기·매거진 분야 머리), 자물쇠 표시(목록·첫 소식·매거진 카드·표지·타임라인), '같은 소식을 무료로 읽기' 상자, 오늘 호 진행 막대·완독 띠(그날은 새 소식 띠 없음), 저녁 정리 상자, 설정 '회의·발표 중에는 조용히'·낱말 바로 저장(0.6초)·이미 받은 목록에 바로 적용·글꼴 즉시 반영·단축키 목록, 상단바 머리 회의 중 아이콘, X11 전체 화면 감지(`focus_x11.rs`).
- 고친 것: Ollama 클라우드 모델(이름에 cloud)을 '기기 안' 요약에 쓰던 문제 — 이 Mac 의 `gpt-oss:120b-cloud` 가 골라지고 있었다. 화면의 prefs 사본이 핵심이 쓴 값(완독 날짜·같은 소식 기준 버전)을 덮어쓰던 문제.
- FEATURES '리' 열: C-08 ✓(병합 중 ☐ 로 되돌아갔던 칸), G-14·G-15·N-26·M-23·H-03~H-05 ✓, N-25·M-24 ~(사유 적음). 빈칸·☐ 없음.
- 시험: `cargo test` 전체 통과(핵심 156 · 화면 6, 새 extras_tests 30 — 맥 ExtrasTests 이식 + 짧은 글 추출·tesseract TSV·클라우드 모델 제외), 리눅스 전 기능 형 검사(`scripts/check-linux-features.sh`) 통과. 사진 점수는 맥 DB 에 맥이 잰 실제 사진 16장을 받아 재어 통과 12·뺌 4 판정이 모두 같음(tesseract 없이 어림으로).
- 이 Mac 에서 앱 실행·PNG 확인(시험 폴더): 분야 고르기 유리 카드(사진 채워짐), WSJ Markets 기사 읽기 창의 '같은 소식을 무료로 읽기: CNBC'(실제 피드 388건 중 유료 표시 45건), 오늘 호 0/16 → 완독 띠, 정치 지면 저녁 정리(이 Mac 에 로컬 Ollama 글 모델이 없어 견본 문장), 목록·매거진 카드 키보드 선택·지면 넘기기·읽기 창 J.
- 리눅스에서 볼 것: README '리눅스에서 확인할 목록' 13·14.

## 2026-10-14 오후 — 따라잡기 2차(맥 남은 개선 2차) 완료

- S-12 받는 크기 상한: `FetchLimit`(피드·사이트맵·채널 찾기 10MB · 기사 페이지 2MB · 사진 8MB), `net::collect` 가 헤더 길이로 미리 거절하고 받는 도중 넘으면 끊음, 304·오류 응답 본문은 받지 않음, `FeedError::TooLarge`("응답이 너무 커서 받다가 멈춤(10MB 넘음)"). 2MB 넘는 기사 페이지는 빠른 길을 건너 느린 길로.
- T-08: `translate_many_reporting` 으로 이 기사에 실제로 쓴 엔진을 표시(앱 전체 last_engine 대신), 4500자 넘는 문단은 문장 단위(`sentence_chunks`)로 나눠 보내고 이어 붙임.
- N-27 지켜볼 낱말: `watch_words.rs`(영어 낱말 경계·한중일 부분 일치, 하루 정리), 알림 정책 `watched`(분야·모드와 상관없이, 전체 상한이면 고임·국내 8곳 이상이면 넘음), 아침 브리핑 시각 창(정한 시각~정오 전 — 아침 브리핑도 같은 창으로 맞춤)에 하루 한 번 정리 물방울·시스템 알림 → 매거진 검색, 목록 줄 눈 표시, 설정 '거르기'에 칸. 상태 `watchKeywords`·`lastWatchDigest`·기사 `watch` 는 맥과 같은 이름.
- P-08 내 기록: `backup.rs`(맥 Backup.swift 와 같은 파일·합치기·되돌리기 규칙, 가져오기 전 `backups/before-import-*.json` 최근 5개), 설정 '일반 › 내 기록'(내보내기·가져오기·되돌리기, GTK FileDialog). 맥이 만든 파일 모양을 그대로 읽는 시험 포함.
- 맥 점검 A-31: guid·link 가 모두 빈 글은 제목+날짜 FNV-1a `noid-…`(맥 Swift 로 잰 값과 같음).
- FEATURES '리' 열: S-12·T-08·N-27·P-08 ✓ — 빈칸·☐ 없음.
- 시험: `cargo test` 전체 통과(핵심 177 · 화면 6, 새 extras2_tests 21), 리눅스 전 기능 형 검사 통과. 앱 실행(시험 폴더): 내보내기 → 같은 파일 가져오기 = "새로 더할 것이 없었습니다", 되돌리기 파일 생김·되돌림, 지켜볼 낱말 정리 물방울(눈 아이콘·'검색 결과'), 설정 거르기 탭의 지켜볼 낱말 칸 PNG 확인.
- (이때 범위 밖으로 둔 맥 SourceFilter 는 같은 날 저녁 S-13 으로 반영 — 아래 절.)

## 2026-10-14 저녁 — S-13 끈 출처 글 바로 빼기(맥 SourceFilter)

- 핵심 `source_filter.rs`(보이는 출처 = 목록에 있고·켜져 있고·숨기지 않은 것) 한 곳. `AppModel::visible_recent`·`source_filter`·`story_items`·`search`·`subscriptions_changed`(켜기·끄기·지우기·분야·숨기기 직후 대기열 정리·안 읽음 수 다시 세기·화면 갱신).
- 적용: 상단바 목록·안 읽음 탭 수·안 읽음 수(상태 `unreadKeys` — 맥과 같은 이름, 예전 파일은 줄이기만), 매거진 오늘·이번 주·지난 호·분야 지면·표지(`resolve` 가 거름), 스토리 목록·크기(보이는 출처로 두 곳 이상만), 검색, 무료 보도 추천, 지켜볼 낱말 정리, 단축키 '가장 최근 소식'·아침 브리핑 수.
- 맥과 같이 바꿈: 숨기기는 이제 글을 지우지 않고 거르기만(숨김을 풀면 돌아옴), '알리지 않음' 낱말도 이미 받은 목록에서 지우지 않고 거르기만(낱말을 지우면 돌아옴).
- 시험: `source_filter_tests` 8개(맥 SourceFilterTests 6 + 안 읽음 다시 세기 + 끄기·다시 켜기·숨기기·낱말 → 목록·안 읽음 수·오늘 호·지난 호·스토리·검색 반영). 전체 통과, 리눅스 전 기능 형 검사 통과.
- FEATURES: S-13 행 추가, 리 열 ✓.

## 2026-10-14 — 보안 점검 고침(리눅스)

- 공개 노출: 바이라인 예시·시험 문자열의 실제 기자 이름·이메일을 맥과 같은 가상 문자열(`김가람 기자 reporter@example.com`, `이나래 기자 desk@example.com …`)로. linux/ 전체에서 다른 실명·실제 이메일 없음 확인(언론사 도메인 주소는 공개 피드 주소라 둠).
- 숨은 웹 보기(L1): 내려받기 시작되면 바로 취소(`download-started`), 응답 결정에서 웹 보기가 보여 줄 수 없는 종류·`Content-Disposition: attachment` 는 거절(`url_safety::web_response_allowed`), `data:` 이동 거절.
- 설정 값 묶기(L6·맥 M5): 상태 파일을 읽을 때 `Settings::clamp`(간격 1~1440분·시각 0~23·상한·문턱), 확인 반복도 1~1440분으로 묶음(큰 값 곱셈 넘침·0 이하 쉬지 않고 받기 막음).
- 기록 가져오기(L6·맥 M5): `backup::sanitize` — 맥·윈도우와 같은 규칙(간격 2·5·10·15·30 외에는 5, 브리핑 5~12시, 낱말 40자·200개, 분야·분야 정책 범위, 직접 추가한 출처는 custom- id·공개 주소·#색·피드 형식만, 기본 출처를 흉내 낸 것 버림, 저장·스크랩은 공개 http(s) 링크만, 폴더 60자), 파일 50MB 상한(`read_file`). 출처 색이 CSS 에 들어가는 `tint` 도 #16진수·글자 이름만.
- 사이트맵 정규식(맥 M4): 앱에 든 기본 출처(같은 id·같은 정규식)의 것만(`feed_service::sitemap_pattern`).
- 사진 압축 폭탄(L3): 풀 때 가로·세로 8192 · 128MB 한도.
- 파일 권한(L7): 데이터 폴더 0700, 저장 파일(원자적 쓰기) 0600.
- 16진수 IP(맥 M6): 리눅스는 URL 정규화 뒤 검사로 이미 거절되고 있었음(재현 시험 통과) — 맥과 같은 명시 규칙도 더함. 특수 대역(L9): 192.0.2/24·198.51.100/24·203.0.113/24·100::/64·2001:db8::/32·2001::/32(Teredo)·3fff::/20·64:ff9b:1::/48.
- Ollama(L5): `/api/tags` 의 remote_host·remote_model 이 붙은 원격 모델도 거름(이름에 cloud 가 없어도).
- 배포판 경로(L8): 개발용 자원 경로(`CARGO_MANIFEST_DIR`)는 debug 빌드에만.
- 시험: 새 `security_tests` 10개 — 고치기 전 8개 실패 확인(16진수 IP·웹 보기 응답 2개는 새 함수·이미 막힘), 고친 뒤 전체 통과. `cargo test` 전체 통과(핵심 195 · 화면 6).
- 범위만(이번에 안 함):
  - L2 시스템 프록시(HTTP(S)_PROXY)가 있으면 이름 확인 뒤 IP 고정·접속 IP 확인이 빠짐 — 프록시 모드에서 미리 푼 IP 로 CONNECT 하거나 프록시를 거친 응답은 출처 피드에만 허용하는 구조 변경이 필요.
  - L4 번역이 늘 Google 로 — '번역 안 함'·배경 제목 번역 옵트인 설정(설정 항목·상태 파일 추가라 맥과 함께 정할 일).
  - L8 시험 훅을 cfg 로 감싸기 — 지금은 환경 변수가 있어야만 켜짐(확인). 배포 빌드에서 빼려면 기능 플래그 정리 필요.
  - 이미 저장소 이력(이전 커밋)에 남은 실명 문자열은 이력 재작성이 필요하므로 관리자 판단.

## 2026-10-15 — 따라잡기 3차(새 FEATURES 행 · e2e-fix 이식)

- 새 행 R-19~R-22 · M-25~M-27 · I-01~I-06 의 '리' 칸을 채움(☐ 없음).
  - 읽기: 찾기 셈을 핵심 `reader_find.rs` 로(악센트·전각 무시), `cover_pick.rs`(맥 HTMLScan 처럼 `<meta>` 하나씩 — 매거진 사진 채우기 `feed_service::og_image` 도 이 함수로 바꿔 og:image:type 을 주소로 잡던 문제 없앰), `body_cleanup::hidden`(뺀 그림 바로 뒤 설명도 뺌), 사진 도구 `reader_image.rs` + `image_text.rs`(Vision 대신 tesseract TSV — R-20 ~).
  - 매거진: 분야 지면 `live_section`(그 분야만·채널 지면 없음·40건)·머리 숫자 `subtitle`/`section_subtitle`(실린 수 기준)·AI 하위 칩 합, 스토리 분야 다수결 `story_topic`, `unseen_reports`·`pick_weekly_quotes`·`is_sunday_evening` 를 핵심으로(시험).
  - 연동: `url_router.rs`(dropcap:// — open·magazine·save, 바깥 요청 1분 10번), `save_link.rs`, `search_index.rs`(GNOME 검색 공급자·KRunner), `scrap_export.rs`(노트 폴더 `<이름>.md`), 명령줄 `--latest`·`--save`·`--magazine`, 상단바·매거진 저장 '주소로 추가…', 설정 › 스크랩북(북마클릿·노트 폴더). 새 설정은 데이터 폴더 `integrations.json`(없거나 깨지면 기본값 — 데스크톱 검색만 켬, 예전 판은 이 파일을 읽지 않음). 위젯(I-01)은 ⊘, 단축어(I-02)는 명령줄로 ~, 서비스 메뉴(I-05 일부)는 ⊘.
- e2e-fix 6건 이식(맥 efdeb13):
  - G-05·G-08: `SectionPolicy.less`(JSON `less`, 예전 파일 → false) — 덜 받기한 분야는 주요 뉴스 흐름으로 안 떨어짐, 누를 때 안내 "이 분야는 저녁 묶음으로 모아 드릴게요"/"매거진에만 실을게요", 즉시로 되돌리면 풀림.
  - G-02: `sections::hits`·`Placement.strong`·`NewsItem::extra_topic`(목록 줄·첫 소식에 칩 하나 더), `notify_section_of`.
  - M-17: `scraps.json` 사본(원자적 쓰기, 맥과 같은 `{version, scraps}`), DB 가 깨지면 `.broken.sqlite` 에서 `import_scraps`, 새로 만든·빈 DB 면 사본에서 되살림(평소에 다 지운 것은 안 되살림). 끄기 `prefs.json` `scrapsCopyOff`. 예전 판은 사본을 모르고 무시.
  - R-08: 실제로 바뀐 외국어 문단 수로 `engine_label`(0이면 표시 없음·일부면 '일부 번역').
  - N-05: 리눅스 물방울 머리 줄은 처음부터 칩·외 N곳 너비를 먼저 잡고 출처명만 줄임 — 고칠 것 없음 확인.
- 문서: C-15 설명을 지금 기준(고유명사 2개 이상 + 적은 쪽의 절반 이상)으로, S-13 낡은 줄 정리, README 첫 소개 문장, '리눅스에서 확인할 목록' 17~22, AppImage 에 검색 공급자 파일 사본.
- 시험: 새 `e2e_fix_tests` 8 · `reader_catchup_tests` 13 · `magazine_catchup_tests` 7 · `integrations_tests` 19. `cargo test --workspace` 전체 통과(핵심 242 · 화면 5), 리눅스 전 기능 형 검사(`scripts/check-linux-features.sh`) 통과. 앱 창은 띄우지 않음(화면 동작은 README 확인 목록 17~22).

### 사이드바 맞추기(맥 4e27109) — 리눅스와 다른 점(→ 2026-10-15 linux-sidebar-translateoff 에서 이식, 아래 절)

분야 지면(M-25)·스토리 분야 다수결(M-26)·머리 숫자 '… 건 중 M건 실음'은 FEATURES 행이라 이번에 반영했다. 그 밖에 리눅스에 없는 것:

1. 이번 주 범위: 맥은 달력 한 주 시작~지금(지난 주간과 이어짐), 리눅스 `live_weekly` 는 아직 '지금부터 7일 전'(지난 주간과 날이 겹침).
2. 주간 표지: 맥은 그 주 가장 많이 다룬 이야기(스토리 보도 수 → 점수), 리눅스는 점수 1등(오늘 표지와 같아질 수 있음).
3. 지난 호 순서: 맥은 호 끝 시각 순(주간은 그 주 끝), 리눅스 `db.issues` 는 만든 시각 순.
4. 예전 호 다시 엮기(`needsRebuild`): 분야 개편 전 호를 지금 규칙으로 — 리눅스에 없음.
5. 기록 적은 호(기사 5건 미만): 맥은 지난 호 목록에서 흐리게 + 머리 '기록 적음' — 리눅스에 없음.
6. 빈 검색 화면: 맥은 지켜볼 낱말·최근 검색 칩(8개)·도움말 — 리눅스에 최근 검색 기억 없음.
7. 저장·스크랩북 머리에 왼쪽 목록과 같은 수(맥 '저장 N건') — 리눅스 매거진 저장 머리에 수 없음(스크랩북은 확인 안 함).
8. 카드 사진이 칸 너비를 밀어 4열에서 겹치던 문제(맥 SwiftUI 배치 문제) — 리눅스는 격자 칸 너비를 고정해 그리므로 해당 없음으로 보이나 화면 확인은 안 함.

## 2026-10-15 — 보안 남은 항목 L2 · L8

- L2 시스템 프록시(관리자 결정 — 맥 기존 동작과 같게): 프록시가 설정돼 있어도 `net::get` 은 보내기 전에 단계(리다이렉트 포함)마다 앱이 이름을 풀어 공개 대역이 아니면 막는다(`allowed` → `url_safety::resolves_public`, 프록시 자신의 이름을 주소로 쓰면 막음). 출처 밖 주소(사진 CDN·기사·번역)는 그대로 프록시로 보낸다 — '출처 피드 도메인만' 방식은 쓰지 않음(맥에서 프록시 사용자에게 사진·번역이 막혀 되돌림). 코드는 바꾸지 않고 시험 `proxy_tests`(가짜 프록시: 내부망으로 풀리는 이름은 프록시로 안 나감 · 출처 밖 공개 주소·출처 피드는 프록시로 나감)로 지킴. 읽기 창(WebKit) 하위 요청은 `guard_proxy` 가 검사한 IP 로 직접 붙어 시스템 프록시를 쓰지 않음.
  - **받아들인 위험**: 프록시를 거치면 실제 연결할 곳의 이름을 프록시가 다시 푼다. 앱이 확인한 뒤 DNS 응답이 내부 주소로 바뀌면(DNS 바꿔치기) 요청 한 번이 프록시를 통해 내부망으로 갈 수 있고, 접속 IP 가 프록시 것이라 받은 뒤 확인도 못 한다. 프록시를 설정한 환경(회사망 등)에서만 생기며, 앱이 확인한 이름 결과는 5분 기억한다.
- L8 시험 훅: `test_hooks::var` 한 곳 — `DROPCAP_TEST_*`·`DROPCAP_SECTIONS`·`DROPCAP_CATEGORIES` 는 개발 빌드(debug)나 `--features test-hooks` 에서만 듣는다(배포 빌드에서는 변수가 있어도 꺼짐). 핵심·화면 모두 이 함수로(app.rs Env·test_extras·toast·reader_view·integrations·focus_guard·magazine·sections·category). `DROPCAP_DATA_DIR`·`DROPCAP_RESOURCES`·`DROPCAP_OLLAMA_MODEL` 은 사용 설정이라 그대로. 개발 경로(`CARGO_MANIFEST_DIR`) 후보는 이미 debug 빌드에만(app.rs `resource`).
  - 시험 `test_hooks_tests`: 고치기 전 `cargo test --release` 실패(배포 빌드에서 DROPCAP_TEST_WEEKLY 가 들음) → 고친 뒤 통과, 개발 빌드에서는 훅이 그대로 듦.
- 시험: `cargo test --workspace` 전체 통과(핵심 244 · 화면 5, 새 proxy_tests 1 · test_hooks_tests 1), `cargo test --release --test test_hooks_tests` 통과, 리눅스 전 기능 형 검사 통과.

## 2026-10-15 — 사이드바 맞추기 이식 + 번역 안 함(linux-sidebar-translateoff)

사용자 결정: 사이드바(맥 4e27109) 이식, 번역은 맥과 같은 '엔진 고르기'(리눅스엔 기기 내 없음).

- 사이드바(위 차이 목록 1~8):
  1. 이번 주 = 달력 한 주(일요일 0시)~지금 — `magazine::week_range`, `live_weekly`·지난 주간 발행이 같은 범위(겹치지 않고 이어짐).
  2. 주간 표지 = 그 주 보도가 가장 많은 스토리(보도 수 → 점수, `weekly_cover_order`). 오늘 호는 점수 순 그대로.
  3. 지난 호 순서 `archive_order`(호 끝 시각 순, 같으면 주간 위). DB 정렬 값도 끝 시각이었지만 같은 값일 때를 맞추고 시작 시·발행 시 모두 거침.
  4. 예전 호 다시 엮기 `needs_rebuild`(분야 id 없는 기사 지면 + 예전 AI 분류) → `publish_due` 가 그 기간 기사로 다시 엮음(기사가 지워져 0건이면 그대로).
  5. 기록 적음(`THIN_ISSUE` 5): 옆 목록 흐리게(0.55) + 도움말 '기록 적음 — 소식 N건', 머리 '지난 호 · 기록 적음'.
  6. 빈 검색 화면: 지켜볼 낱말·최근 검색 칩(prefs.json `magRecentSearches` — 맥 AppStorage 와 같은 이름, 2글자 이상 8개, 입력 확정·결과 있던 채로 떠날 때 기억)·'최근 검색 지우기'·도움말.
  7. 저장 머리 'N건', 스크랩북 머리 '모두 N개'(옆 목록 수와 같음).
  8. 카드 사진: 리눅스에도 같은 문제가 있었다 — 사진 칸(DrawingArea) 최소 너비 300 이 격자 칸 230 보다 넓어 좁은 4열에서 칸을 밀었음. `CARD_PHOTO_MIN_WIDTH` 120 ≤ `CARD_MIN_WIDTH` 230.
  - 이미 있던 것: 분야 지면(M-25)·오늘 칩 건수 뺌·AI 하위 '기타' 칩·머리 숫자·스토리 다수결. 이번 주 머리 '이번 주 · …' 도 맞춤.
- 번역 안 함(보안 L4 · 배경 제목 번역 옵트인 포함):
  - 설정 키 `translateEngine`(상태 파일 settings — 맥·윈도우와 같은 키·값 `auto`·`apple`·`google`·`off`, 예전 파일·모르는 값은 `auto`, 기록 가져오기도 clamp 로 묶음). 리눅스 `auto` = Google, `apple`(맥에서 '기기 내만'을 가져온 기록) = 보내지 않음.
  - `Translator` 가 번역할 때마다 AppModel 설정을 읽고(`set_mode_source`), 보내지 않는 방식이면 기사 본문·요약 대체문·배경 제목 번역(확인·채우기·첫 호)·영어 제목(T-04)·사진 속 글자 번역 모두 원문 그대로·엔진 없음(읽기 창 번역 표시 없음). 방식이 바뀌면 캐시를 비움(케이스 11).
  - 설정 › 번역 방식: 자동 (Google 번역) · Google 번역 · 번역 안 함(apple 기록이면 그 항목도) + 개인정보 안내 'Google 번역으로 본문 문단이 전송됩니다(…)'. README '리눅스의 한계' 번역 줄도 같은 안내.
  - 번역 응답 상한 `TRANSLATE_MAX_BODY` 2MB(전에는 일반 상한 32MB, 윈도우 maxBody 와 같게).
- 시험: 새 `sidebar_tests` 7(맥 SidebarRuleTests·SidebarEditorTests 중 없던 것) · `translate_off_tests` 6 · 화면 `card_photo_does_not_push_column` 1.
  - 고치기 전: 주간 표지·예전 호 다시 엮기 시험이 실패(표지 `openai|sb-lab`, 다시 엮은 호 1건 ≠ 3건), 나머지는 새 함수·설정이 없어 컴파일 실패(카드 사진 너비는 300 > 230). 고친 뒤 모두 통과.
  - `cargo test --workspace` 전체 통과(핵심 257 · 화면 6), 리눅스 전 기능 형 검사 통과. 앱 창은 띄우지 않음(README 확인 목록 23·24).
- FEATURES '리' 칸: M-05 · M-08 · M-15 · M-16 · P-02.
- 워크트리: `wt/linux-native` 는 main 에 이미 병합돼 있어 지우고 다시 만드는 대신 main 으로 fast-forward(같은 결과, 빌드 캐시 유지).

