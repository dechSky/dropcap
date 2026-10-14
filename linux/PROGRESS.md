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
| C-15 | ~ 낱말 규칙은 맥과 같음. 뜻 비교(맥 NLEmbedding)는 "고유명사 2개+어간 3개 겹침"으로 대신 — 맥 시험 사례 그대로 통과 | story_match.rs |
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
- 이번에 안 한 것: 맥의 SourceFilter(끈·해지한 출처 글을 목록·매거진에서 바로 빼기)는 FEATURES 항목이 없어 범위 밖으로 두었다 — 필요하면 지시 바람.
