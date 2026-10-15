# KR1 출처 점검 도구

`mac/sources-audit/<출처id>.md` 와 `_KR1.md` 를 만든 도구. 앱 코드는 고치지 않는다(분석만).

| 단계 | 파일 | 하는 일 |
|---|---|---|
| 1 | `feeds.py` | 목록(탭 구분: id·이름·종류·기본켜짐·paywall·피드)의 피드를 받아 넘어오는 것(요약 길이·HTML·전문·사진·분야·기자·날짜·링크)을 재고 출처마다 3건을 고른다 → `feeds.json` |
| 2 | `KR1Probe.swift` + `run-probe.sh` | 고른 기사를 앱과 같은 길(`FeedService.items` → `ArticleExtractor.extract(allowScripts: true)`)로 추리고, 읽기 창이 숨기는 블록(BodyCleanup·잡그림·표지와 같은 사진)을 표시 → `app-<id>.json`. 시험 파일은 돌릴 때만 `Tests/DropcapTests` 에 복사하고 끝나면 지운다 |
| 3 | `site.mjs` | 헤드리스 Chromium(화면·포커스 안 씀)으로 기사를 열어 본문 영역(사이트별 선택자 → 없으면 일반 규칙)의 문단·글자·사진·설명·소제목·목록·표·끼운 영상·'더 보기'를 재고 스크린샷 → `site-<id>.json`, `<id>-<n>.png` |
| 4 | `compare.py` | 앱 블록과 사이트 본문을 맞대어 글자 비율·문단 덮기·빠진 줄·섞인 줄(군더더기 꼴)·사진/설명 짝 → `cmp-<id>.json` |
| 5 | `report.py` + `notes.json` | 지표와 사람이 적은 판단(판정·메모·규칙)으로 md 를 쓴다. 본문·기자 이름은 쓰지 않고 종류·개수만 |

## 지표

- **덮기**: 사이트 본문 영역의 문단다운 줄(40자 이상, 광고·관련기사·군더더기 꼴 제외) 글자 가운데 우리 블록(숨긴 것 포함)에 든 비율. 완전성 판정은 이것으로 한다.
- **우리 / 사이트 글자**: 공백 뺀 글자 수. 사이트 쪽은 구독 단추·재생기·기자 줄 같은 짧은 군더더기 줄을 뺀 값. 100%를 넘으면 대개 우리 쪽에 섞인 것이 있다.
- 사이트 쪽 '유료/로그인' 낱말 표시(flags.paywall)는 바닥글·댓글 칸에도 걸려 믿지 않는다 — 유료 여부는 본문 끝맺음·페이지 자료(예: 한경 `articlePayment`)로 따로 확인했다.

## 다시 돌리기

```sh
OUT=<저장소 밖 폴더>/data; SHOTS=<저장소 밖 폴더>
python3 -I feeds.py <목록.txt> $OUT                       # [id,…] 를 붙이면 그 출처만
bugak run --heavy -- sh run-probe.sh $OUT/feeds.json $OUT  # 앱 빌드·시험(무거움)
PW_REQUIRE=<playwright 가 든 package.json> PW_EXEC=<chrome-headless-shell> node site.mjs $OUT/feeds.json $OUT $SHOTS
python3 -I compare.py $OUT
python3 -I report.py $OUT <저장소>/mac/sources-audit
```

- 요청 사이 1.5초, 출처마다 3건. 막히면(captcha·403) 그 출처는 '차단'으로 적는다.
- 결과 자료(`*.json`, 블록 원문 포함)와 스크린샷은 **저장소 밖**에만 둔다(공개 저장소).
- 피드는 빠르게 바뀐다: 1단계와 2단계 사이가 길면 앱의 피드 읽기에 고른 기사가 없을 수 있다(본문 추출은 주소로 하므로 영향 없음, `app` 칸만 빔).
