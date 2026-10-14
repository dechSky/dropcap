# 웹 화면 규약(윈도우 판)

트레이 창·설정·읽기 창·매거진은 WinUI 3 창 안의 WebView2 가 `web/<화면>.html` 을 띄운 것이다.
화면은 그리기만 하고, 거르기·정렬·저장 같은 판단은 C# 화면 처리기(`IPage`)가 한다(맥에서 `dotnet test` 로 시험).

## 파일

| 화면 | C# 처리기 | 웹 |
|---|---|---|
| menu (트레이 창, U) | `MenuPage.cs` | `web/menu.{html,css,js}`, `web/mock/menu.js` |
| settings (P·K) | `SettingsPage.cs` | `web/settings.*`, `web/mock/settings.js` |
| reader (R) | `ReaderPage.cs` | `web/reader.*`, `web/mock/reader.js` |
| magazine (M) | `MagazinePage.cs` | `web/magazine.*`, `web/vessel.js`, `web/mock/magazine.js` |

공용(바꾸지 말 것 — 필요하면 요청): `Bridge.cs`(IPlatform·IPage·Bridge·Args), `Views.cs`(ItemView·VesselView·Lookup), `web/base.css`, `web/bridge.js`, `web/ui.js`.

## 다리

- 화면 → 앱: `bridge.send(cmd, args)` → Promise. 앱의 `IPage.Handle(cmd, args)` 가 돌려준 값이 JSON(camelCase)으로 온다. 첫 명령은 `ready`.
- 앱 → 화면: `bridge.on('changed', fn)` 등. 앱은 `Bridge.Emit(page, event, data)` 로 보낸다. 공용 알림: `changed`(상태 바뀜 — 다시 물어보기), `shown`(창이 다시 보임), `appearance`({pretendard, reduceMotion}).
- 미리 보기: WebView2 밖에서는 `web/mock/<화면>.js` 의 `window.DropcapMock(cmd, args)` 가 답한다. 맥에서 `python3 -m http.server` 로 빌드 결과의 `web/` 를 띄워 브라우저로 확인한다(글꼴은 빌드 때 `web/fonts/` 에 복사됨).

## 안전

- 모든 글자는 `ui.esc()` 를 거쳐 넣는다(기사 제목·요약은 바깥에서 온 글자). 색은 `ItemView.SafeColor` 를 거친 `#RRGGBB` 만.
- 사진은 `bridge.img(url)` 로만(앱의 안전 로더 `https://img.dropcap.example/?u=` — S-07·R-18). `<img src>` 에 바깥 주소를 직접 넣지 않는다.
- 각 html 머리의 CSP(`default-src 'self'; img-src 'self' https://img.dropcap.example data:; script-src 'self'; connect-src 'none'`)를 그대로 둔다. 인라인 스크립트 금지(파일로).
- 바깥으로 여는 링크는 앱 명령으로(C# 에서 `ExternalLink.Open` — S-08). `<a href>` 로 바깥에 가지 않는다.

## 모양

- 글꼴·색: `base.css` 의 변수(`--text`, `--text-2`, `--fill`, `--accent`, 분야 `cat-<id>` → `--cat`, 종류 `kind-<id>`). 라이트·다크 모두.
- 아이콘: `ui.ic('bell')` · `<i data-ic="bell"></i>`(이름은 `ui.js` 의 표).
- 메뉴: `ui.popMenu(x, y, items)` · `ui.popUnder(el, items)`.
- 맥 SwiftUI 의 크기·간격·문구를 그대로(맥 코드가 기준). 단축키 표기는 Ctrl(맥 ⌘ 대신), 맥 ⌥⌘M → Ctrl+Alt+M.
- 움직임은 CSS 로. `html.reduce-motion` 이면 모든 움직임이 꺼진다.
