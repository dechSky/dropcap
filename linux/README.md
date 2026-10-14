# Dropcap 리눅스 판

맥 앱(`mac/`)과 같은 기능·문구·수치를 GTK4 · libadwaita 네이티브로 옮긴 판입니다. 기능 목록과 상태는 `docs/FEATURES.md` 의 "리" 열.

- Rust · GTK4(4.14 이상) · libadwaita(1.5 이상)
- GNOME · KDE, X11 · Wayland
- 핵심(수집·안전·번역·저장·매거진 DB·분야별 알림 정책)은 화면 없는 `dropcap-core`, 화면은 `dropcap-gtk`
- 분야·출처 자료는 맥과 같은 `shared/categories.json`·`shared/sources.json` 을 실행 파일에 담는다(시험용으로 `DROPCAP_SECTIONS` 로 바꿀 수 있음)

## 빌드

### 리눅스(배포판)

```bash
# Debian/Ubuntu 24.04 이상
sudo apt install build-essential pkg-config libgtk-4-dev libadwaita-1-dev \
  libwebkitgtk-6.0-dev libgtk4-layer-shell-dev libasound2-dev speech-dispatcher
# Fedora 40 이상
sudo dnf install gtk4-devel libadwaita-devel webkitgtk6.0-devel gtk4-layer-shell-devel speech-dispatcher
# Arch
sudo pacman -S gtk4 libadwaita webkitgtk-6.0 gtk4-layer-shell speech-dispatcher

cd linux
cargo test -p dropcap-core                      # 핵심 시험(바깥 서버 시험은 DROPCAP_LIVE_TESTS=1)
cargo build --release -p dropcap-gtk --features linux
./target/release/dropcap
./scripts/build-appimage.sh                     # dist/Dropcap-<버전>-<아키텍처>.AppImage
```

`--features linux` 는 다음을 모두 켭니다. 하나씩 끌 수도 있습니다(`--features webkit,tray` 처럼).

| 기능 | 하는 일 | 없으면 |
|---|---|---|
| `webkit` | 읽기 창의 느린 길(스크립트로 그리는 사이트)·Readability.js(WebKitGTK 6) | 빠른 길(스크립트 없이 Rust 판 Readability)만 |
| `layer-shell` | Wayland(KDE·Sway 등)에서 물방울을 화면 위쪽에 | GNOME Wayland 처럼 시스템 알림으로 |
| `tray` | 트레이 아이콘(StatusNotifierItem) | 앱을 다시 실행하면 상단바 창이 열림 |
| `x11` | X11 작업 영역·클릭 통과·전역 단축키 | 단축키 없음, 물방울은 화면 위쪽 가운데 |
| `notify` | 시스템 알림(org.freedesktop.Notifications) | 물방울만 |
| `speech` | 소리 내어 읽기(speech-dispatcher `spd-say`) | 단추 숨김 |

### 이 맥에서(개발)

```bash
brew install gtk4 libadwaita pkgconf
cd linux && cargo run -p dropcap-gtk     # 리눅스 전용 기능 없이 빌드·실행
```

## 데이터 폴더

`$XDG_DATA_HOME/dropcap` (보통 `~/.local/share/dropcap`). `DROPCAP_DATA_DIR` 로 바꿀 수 있습니다.
설정(`native-state.json`)·화면 설정(`prefs.json`)·매거진 기록(`magazine.sqlite`)·출처 건강(`source-health.json`)·기사·사진 캐시. 파일 모양은 맥 판과 같습니다. 상태 파일이 깨지면 `.bak` 에서 되살리고, 깨진 파일은 `.broken.json` 으로 남깁니다.

## 시험용 환경 변수

```bash
DROPCAP_TEST_TOAST=1 dropcap                 # 실행하자마자 알림 미리 보기
DROPCAP_TEST_BUNDLE=economy dropcap          # 견본 묶음 카드(G-07)
DROPCAP_TEST_MAG_PAGE=section:ai dropcap     # 매거진의 그 지면(scrapbook·saved·search·week·story:<id>)
DROPCAP_TEST_BURST=1 dropcap                 # 견본 알림 3건
DROPCAP_TEST_URL=<기사 주소> dropcap         # 읽기 창 바로
DROPCAP_TEST_MAGAZINE=1 dropcap              # 매거진 바로 (DROPCAP_TEST_MAG_PAGE=scrapbook)
DROPCAP_TEST_MENU=1 dropcap                  # 상단바 창 바로
DROPCAP_TEST_SETTINGS=1 dropcap              # 설정 바로
DROPCAP_TEST_SHOT_DIR=/tmp/shots dropcap     # 위 창들을 PNG 로 남김(화면 캡처 권한 없이)
DROPCAP_TEST_QUIT_AFTER=30 dropcap           # 30초 뒤 스스로 종료
DROPCAP_DATA_DIR=/tmp/dropcap-test dropcap   # 실제 기록을 건드리지 않는 시험용 폴더
DROPCAP_REDUCE_MOTION=1 dropcap              # 움직임 줄이기
DROPCAP_OLLAMA_MODEL=qwen2.5 dropcap         # 3줄 요약에 쓸 Ollama 모델
```

## 리눅스의 한계와 대신 한 것

- **번역**: 무료 기기 내 번역이 없어 Google 번역 공개 엔드포인트를 씁니다(기사 문장이 Google 로 전송됨).
- **3줄 요약**: 이 컴퓨터에서 [Ollama](https://ollama.com) 가 돌고 있으면 그걸로(`http://127.0.0.1:11434` 만, 바깥으로 보내지 않음). 없으면 요약 상자를 숨깁니다.
- **같은 소식 묶기**: 맥의 기기 내 문장 임베딩 대신 영어 제목의 고유명사 공유(2개 이상, 적은 쪽의 절반 이상). 맥 시험 사례는 같은 결과.
- **읽기 창 열림**: GTK4 는 앱이 창을 누른 자리에서 키울 수 없어 서서히 나타나게 함. 매거진의 책장 넘기기는 회전 전환으로.
- **GNOME 트레이**: AppIndicator 확장(`gnome-shell-extension-appindicator`)이 있어야 아이콘이 보입니다. 없으면 앱을 다시 실행하면 상단바 창이 열립니다.
- **Wayland**: 앱이 창 위치·전역 단축키를 정할 수 없습니다. layer-shell 이 되는 KDE·Sway 등에서는 물방울이 초점 화면 위쪽에(커서 따라가기 없음), GNOME Wayland 는 시스템 알림으로 자동 전환. 전역 단축키는 X11 에서만.
- **유리 재질**: 반투명 카드(컴포지터가 흐림을 지원하면 흐림).
- **노치**: 맥 전용.

## 리눅스에서 확인할 목록

이 판은 맥에서 개발해 리눅스 전용 부분은 리눅스에서 직접 확인해야 합니다(FEATURES 에 `~ 리눅스 확인 필요`).

1. GNOME(X11)·GNOME(Wayland)·KDE(Wayland)에서 트레이 아이콘이 보이고, 안 읽은 소식이 있으면 채운 모양이 되는지
2. 처음 실행하면 관심 분야 고르기 창이 뜨고, 고른 분야 출처만 켜지는지
3. `DROPCAP_TEST_TOAST=1` — X11: 커서가 있는 모니터의 작업 영역 위쪽 가운데에서 물방울이 떨어지고 카드 밖 클릭이 뒤 창으로 가는지 / KDE Wayland: layer 로 뜨는지 / GNOME Wayland: 시스템 알림으로 바뀌는지
4. 알림이 뜰 때 다른 앱의 입력 초점을 빼앗지 않는지
5. X11 에서 Ctrl+Alt+N · Ctrl+Alt+M
6. `DROPCAP_TEST_URL=https://www.theverge.com/...` — 빠른 길·느린 길(스크립트 사이트) 추출, 번역 바뀜, 소리 내어 읽기
7. 설정 › 로그인할 때 실행 → `~/.config/autostart/io.github.dechsky.Dropcap.desktop` 생기고 다시 로그인하면 창 없이 시작
8. GNOME 방해 금지(배너 끔)·KDE 방해 금지일 때 조용히 쌓이는지
9. `./scripts/build-appimage.sh` 결과가 다른 배포판에서 열리는지(WebKitGTK 보조 프로세스 포함)
10. 알림 카드·목록 줄·매거진 카드의 오른쪽 클릭 '바로 줄이기'(초점을 받지 않는 알림 창에서도 메뉴가 뜨는지)
11. 묶음 알림을 누르면 매거진의 그 분야 지면이 열리는지, OPML 가져오기·내보내기·스크랩 파일 저장(파일 대화상자·포털)
12. 매거진 카드 마우스 올림 확대·시차, 표지 켄 번스, 지면 전환이 배율 2 화면에서 매끄러운지
