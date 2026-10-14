# 읽기 창 모양 · 아무 주소 저장 · 스크랩 노트 폴더 (wt/reader-save)

## 1. 읽기 창 모양 고르기 (G-10)
- 도구 막대의 글자 크기 단추 묶음 → **'모양'(Aa) 단추** 하나. 팝오버: 글자 크기(13–26), 줄 간격(좁게·보통·넓게), 본문 폭(540·660·820), 바탕(자동·종이·어둡게), 글꼴(Pretendard·명조·시스템), '기본값'.
- ⌘- / ⌘= 는 팝오버가 닫혀 있어도 그대로 동작(숨은 단추).
- 값은 @AppStorage: `readerFontSize`(이전 키 그대로) · `readerLineSpacing` · `readerWidth` · `readerTheme` · `readerFont`. 글꼴 값이 비어 있으면 앱 설정(Pretendard 쓰기)을 따른다.
- 명조: 영문은 New York(시스템 명조), 한글은 AppleMyungjo 로 이어 씀(cascade).
- 바탕 '어둡게'·'종이'는 창 전체 모양(제목줄·도구 막대)까지 바꾼다(`WindowAppearance`). '자동'은 시스템 밝은/어두운 화면을 따른다.
- **기사 안 찾기 ⌘F**: 위에 뜨는 찾기 막대, 대소문자·악센트 무시, 모든 일치를 노랑·지금 것은 주황으로 칠하고 그 블록으로 스크롤. ⌘G / ⇧⌘G 다음·이전(끝에서 처음으로), esc 로 닫기. 번역/원문 중 **지금 보이는 글**(제목 포함)에서 찾는다.
- 움직임 줄이기: 바탕 바꿈·찾기 막대·스크롤 애니메이션을 끈다.
- 덤: 주소가 이상한 기사의 공유 단추를 숨김(점검 A-37), 본문에서 뺄 블록 계산을 `hiddenBlocks` 하나로.
- 파일: `Reader/ReaderLook.swift`(새) · `Reader/ReaderFind.swift`(새) · `Reader/ReaderView.swift`.

## 2. 아무 웹 주소를 '나중에 읽기'로 (G-8)
- ① 서비스 메뉴 **'Dropcap 에 저장'** — 받는 형식: URL · HTML(첫 href) · RTF(링크 속성) · 글(첫 주소). 링크 글자를 골랐으면 그 글자를 제목 후보로.
- ② **`dropcap://save?url=<인코딩한 주소>[&title=<제목>]`** — 설정 › 스크랩북에 북마클릿 코드 복사 단추. 앱이 뜨기 전에 들어온 주소는 모아 두었다가 처리.
- ③ 상단바 '저장' 탭과 매거진 '저장' 화면 위에 **'주소로 추가…' 칸**.
- 안전: `normalize` 가 공개 http(s) 만(아이디·암호 든 주소, 2048자 넘는 주소, javascript:/file:/내부망 거절) → 저장 때 `URLSafety.resolvesPublic` 로 이름까지 확인. 바깥(스킴·서비스)에서는 1분에 10건을 넘으면 멈춘다(웹 페이지가 dropcap:// 를 마구 부르는 경우 대비). 결과는 작은 알림(showInfo)으로 알린다. **dropcap:// 로 온 저장은 '저장할까요?' 확인 창**(아무 웹 페이지나 스킴을 부를 수 있으므로 · 보안 점검 반영).
- 기사 머리(og:title·og:image·og:site_name·description, 앞 128KB)로 NewsItem: 출처 = 사이트 이름(없으면 주소 이름), 등급 이름표 '웹에서 저장', sourceId `web:<host>`. 'Initial - Wikipedia' 같은 끝의 사이트 이름은 뗀다. 저장은 기존 `toggleSaved` 를 써서 본문·번역까지 미리 받아 보관(오프라인 읽기).
- 파일: `Core/SaveLink.swift`(새, ServiceProvider 포함) · `UI/AddURLBar.swift`(새). 공유 파일은 한 줄씩: App.swift(설치 1줄·URL 열기 3줄·시험 훅 1줄), MenuView 1줄, MagazineView(SavedView) 1줄, Info.plist(CFBundleURLTypes·NSServices).
- 서비스 메뉴는 /Applications 설치 뒤(또는 `/System/Library/CoreServices/pbs -update`) 나타난다.

## 3. 스크랩 → 노트 폴더 자동 저장 (G-9, D-12)
- 설정에 **'스크랩북' 탭**(SettingsView 1줄): 폴더 고르기/바꾸기/잊기, 켜기 토글(끄기 스위치), 지금 저장.
- 켜 두면 스크랩 추가·수정·삭제·폴더 이름 바꿈 때마다(0.4초 모아서) `<폴더>/<스크랩 폴더 이름>.md` 를 지금의 Markdown 내보내기 형식으로 **원자적 덮어쓰기**. 날짜 줄만 다르면 손대지 않음(동기화 앱이 덜 바쁘게). 빈 스크랩 폴더는 전에 쓴 파일이 있을 때만 비운다. 이름을 바꾸면 예전 이름 파일은 휴지통으로.
- 폴더는 보안 범위 북마크(안 되면 일반 북마크)로 기억. 다른 Mac 에서 풀리지 않으면 쓰지 않고 '다시 골라 주세요'와 예전 경로를 보인다. 파일 이름의 `/ :`·맨 앞 `.` 은 바꿈.
- **Markdown 이스케이프(A-30)**: 제목의 `[ ] \` 앞에 `\`, 주소는 `<…>` 로 감싸고 `< > 공백`은 퍼센트 표기. 여러 줄 메모도 목록 한 칸 안에. (웹·확장 등 다른 앱의 내보내기 형식도 맞추려면 그쪽은 따로.)
- **이번 주 모은 문장**: 일요일 17시부터 매거진 스크랩북 첫머리에 지난 7일 문단 스크랩(같은 문장 한 번, 최근 6개). 새 호 엮기는 하지 않음. MagazineView(ScrapbookView) 1줄.
- 파일: `Core/ScrapExport.swift`(새) · `UI/ScrapbookSettingsView.swift`(새) · `UI/WeeklyQuotes.swift`(새) · `Core/Scrapbook.swift`.

## 시험
- `swift test` **79/79 통과**. 새 `Tests/DropcapTests/ReaderSaveTests.swift`: 주소 정리·거절, 스킴 해석, 서비스 붙여넣기 후보 순서, 기사 머리 해석, 저장 소식 만들기·사이트 이름 떼기, Markdown 이스케이프·여러 줄 메모, 파일 이름·날짜 줄 비교, 모양 값 기억(키 유지·되읽기·기본값), 명조 한글 잇기, 찾기(대소문자·악센트·순서·순환·칠하기), 이번 주 문장 고르기·일요일 저녁. 기존 Markdown 시험 1줄은 새 링크 형식(`<…>`)으로 고침.
- 앱 스냅샷(DROPCAP_DATA_DIR 임시 폴더): 종이+명조+넓은 줄, 어둡게+넓은 폭+찾기 '이니셜'(1/63, 칠함·스크롤 확인), 모양 팝오버·주소 칸·설정 스크랩북 탭·이번 주 문장 밝게/어둡게, 주소 스킴 저장(제목·사이트·등급 확인), 노트 폴더에 `GPT 조사.md` 생성 확인.
- 시험 훅(`UI/ReaderSaveTestHooks.swift`): `DROPCAP_TEST_LOOK` · `_FIND` · `_PANELS` · `_SAVEURL` · `_SCHEME` · `_EXPORT_DIR` · `_WEEKLY`.

## 정해 주시면 좋은 것(기본형으로 동작 중)
- 종이 바탕 색(#F7EFDD·글자 짙은 갈색), 폭 세 단계 값(540/660/820), 이번 주 문장을 보이는 때(일요일 17시~자정).
- 스킴 저장 확인 창: 보안 점검에 따라 기본으로 묻게 했음 — 묻지 않게 되돌릴지.
