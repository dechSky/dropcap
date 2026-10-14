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
