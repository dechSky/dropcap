# Dropcap 리눅스 판

관심 분야(정치·경제·IT·AI 등)의 새 소식을 분야별 알림 정책(즉시·묶음·매거진만)에 따라 화면 위쪽에서 물방울처럼 알려 주고, 하루·한 주의 소식을 매거진으로 엮어 보여 주는 트레이 앱입니다.

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

개발 빌드(`cargo build`·`cargo run`)에서만 듣습니다. 배포 빌드(`--release`)에서 쓰려면 `--features test-hooks` 를 더합니다(`DROPCAP_SECTIONS`·`DROPCAP_CATEGORIES` 도 같음).

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
DROPCAP_OLLAMA_MODEL=qwen2.5 dropcap         # 3줄 요약·저녁 정리에 쓸 Ollama 모델(이름에 cloud 가 든 모델은 쓰지 않음)
DROPCAP_TEST_EXTRAS=/tmp/x dropcap           # 피드를 받은 뒤 유료 기사 읽기 창·오늘 호 진행·완독·저녁 정리를 PNG 로(DROPCAP_TEST_EXTRAS_WAIT=초)
DROPCAP_TEST_ENABLE=wsj-markets dropcap      # 그 출처를 켜고 최근 글을 매거진에 바로 실음(유료 표시 확인)
DROPCAP_TEST_FOCUS=fullscreen dropcap        # 회의·발표 중 감지 결과를 정해 둠(fullscreen·sharing·calendar·none)
DROPCAP_TEST_KEYNAV=/tmp/k dropcap           # 목록·매거진 카드 키보드 탐색, 지면 넘기기, 읽기 창 J 를 PNG 로
DROPCAP_TEST_EXTRAS2=/tmp/e dropcap          # 내 기록 내보내기→가져오기→되돌리기 왕복(로그), 지켜볼 낱말 정리 물방울(SHOT_DIR 이 있으면 PNG)
```

## 리눅스의 한계와 대신 한 것

- **번역**: 무료 기기 내 번역이 없어 Google 번역 공개 엔드포인트를 씁니다. **번역을 켜 두면(자동·Google) Google 번역으로 본문 문단이 전송됩니다**(외국어 기사 제목·같은 소식 묶기용 영어 번역 포함). 설정 › 일반 › 번역 방식에서 '번역 안 함'을 고르면 아무것도 보내지 않고 원문을 보여 줍니다(설정 키 `translateEngine` — 맥·윈도우와 같은 키·값 `auto`·`apple`·`google`·`off`, 리눅스에서 `apple` 은 번역 안 함).
- **3줄 요약**: 이 컴퓨터에서 [Ollama](https://ollama.com) 가 돌고 있으면 그걸로(`http://127.0.0.1:11434` 만, 바깥으로 보내지 않음). 없으면 요약 상자를 숨깁니다.
- **같은 소식 묶기**: 맥의 기기 내 문장 임베딩 대신 영어 제목의 고유명사 공유(2개 이상, 적은 쪽의 절반 이상). 맥 시험 사례는 같은 결과.
- **읽기 창 열림**: GTK4 는 앱이 창을 누른 자리에서 키울 수 없어 서서히 나타나게 함. 매거진의 책장 넘기기는 회전 전환으로.
- **GNOME 트레이**: AppIndicator 확장(`gnome-shell-extension-appindicator`)이 있어야 아이콘이 보입니다. 없으면 앱을 다시 실행하면 상단바 창이 열립니다.
- **Wayland**: 앱이 창 위치·전역 단축키를 정할 수 없습니다. layer-shell 이 되는 KDE·Sway 등에서는 물방울이 초점 화면 위쪽에(커서 따라가기 없음), GNOME Wayland 는 시스템 알림으로 자동 전환. 전역 단축키는 X11 에서만.
- **유리 재질**: 반투명 카드(컴포지터가 흐림을 지원하면 흐림).
- **노치**: 맥 전용.
- **회의·발표 중 조용히**: 전체 화면은 X11 에서만 알 수 있고(Wayland 는 다른 앱 창 상태를 알 공개 방법이 없음), 화면 공유·기록은 기록 앱(OBS·SimpleScreenRecorder·Kooha·wf-recorder 등)이 떠 있는지로 봅니다. Zoom·Meet 의 화면 공유는 따로 뜨는 프로세스가 없어 알 수 없습니다. 캘린더는 데스크톱 공통 일정 저장소가 없어 쓰지 않습니다.
- **분야 대표 사진 점수의 글자 면적**: `tesseract`(한·일·중·영 중 설치된 언어)가 있으면 글자 인식, 없으면 '글자 같은 칸' 어림. 맥이 잰 실제 사진 16장과 판정이 같았습니다.
- **분야별 저녁 정리**: 기기 안 모델은 Ollama. 없으면 상자를 띄우지 않고 알림은 그대로 제목 2줄.

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
13. X11 에서 다른 앱을 전체 화면으로 두거나 OBS 를 켠 동안 물방울 대신 '안 읽음'에 쌓이고 상단바 머리에 이유 아이콘이 뜨는지(Wayland 에서는 기록 앱만)
14. 상단바 창을 열자마자 ↓/J·↑/K·Enter·S·O·M 이 듣는지, 검색칸에서 ↓ 로 목록으로 내려가는지, 매거진 Ctrl+[ · Ctrl+], 읽기 창 J·K·Esc
15. 설정 › 일반 › 내 기록: 내보내기·가져오기 파일 대화상자(포털), 맥·윈도우에서 내보낸 파일을 가져오면 저장·스크랩·구독이 더해지는지, '마지막 가져오기 되돌리기'
16. 지켜볼 낱말 정리 알림(시스템 알림 방식)을 누르면 매거진 검색이 그 낱말로 열리는지
17. `xdg-open 'dropcap://save?url=https%3A%2F%2Fexample.com%2Fa'` — 앱이 떠 있을 때·꺼져 있을 때 모두 확인 창 → '나중에 읽기에 저장했어요', 설정 › 스크랩북의 북마클릿(Firefox·Chromium)
18. `dropcap --save <주소>`·`dropcap --magazine` 이 떠 있는 앱으로 넘어가는지, `dropcap --latest 5 --section 연구`·`--json` 이 창 없이 출력하는지
19. 데스크톱 검색: `packaging/io.github.dechsky.Dropcap.search-provider.ini` 를 `/usr/share/gnome-shell/search-providers/` 에(D-Bus `.service` 는 `/usr/share/dbus-1/services/`) 두면 GNOME 검색에 저장·스크랩 기사가 나오고 누르면 읽기 창 · KDE 는 `.krunner.desktop` 을 `~/.local/share/krunner/dbusplugins/` 에. AppImage 는 이 파일들의 사본을 `usr/share/dropcap/integration/` 에 담음(D-Bus 로 처음 깨울 때 첫 질문이 빈 결과일 수 있음)
20. 설정 › 스크랩북 노트 폴더: 포털 폴더 고르기(Flatpak 경로 포함), Obsidian 보관함에 `<폴더>.md` 가 생기고 폴더 이름을 바꾸면 예전 파일이 휴지통으로, 폴더가 없어지면 '다시 골라 주세요'
21. 상단바 '저장' 탭·매거진 '저장' 의 '주소로 추가…' 칸
22. 읽기 창 사진 도구: 마우스 올림 단추·오른쪽 클릭, tesseract(kor·eng 등) 설치 시 사진 속 글자 번역 창, 없을 때 설치 안내 · Ctrl+F 찾기
23. 설정 › 번역 방식 "번역 안 함": 새 외국어 기사 제목이 원문 그대로이고 읽기 창이 원문만 보이며(번역 표시 없음) 네트워크에 translate.googleapis.com 요청이 없는지, 다시 "자동"이면 번역되는지
24. 매거진: 지난 호 목록의 기사 5건 미만 호가 흐리고 마우스를 올리면 "기록 적음", 머리에 "지난 호 · 기록 적음" / 이번 주 머리 "이번 주 · …" / 저장·스크랩북 머리 수가 옆 목록 수와 같음 / 빈 검색 화면의 지켜볼 낱말·최근 검색 칩 / 좁은 창 4열 카드가 겹치거나 화면 밖으로 나가지 않음
