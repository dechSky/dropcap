# 출처 점검 INTL2 — 해외 25곳 묶음 요약 (2026-10-15)

- 대상: 해외 25곳(기본켜짐 11 · 꺼짐 14) × 기사 3건 = 75건(BBC Technology 첫 기사는 BBC Business 첫 기사와 같은 기사 — 두 피드 중복).
- 앱 결과: 앱과 같은 추출기(`ArticleExtractor().extract(allowScripts: true)`, ReadSweep 재생)로 **63/75 성공** — 빠른 길 62 · 느린 길 1 · 실패 12(NYT 9 = 403, WSJ 3 = 401). 5초 넘음 4건(모두 차단 사이트의 느린 길).
- 사이트 표시: 헤드리스 Chromium(사진·영상·글꼴 안 받음, 요청 사이 1.5초)으로 본문 영역을 잼. **헤드리스에 확인 화면(captcha/403)** 이 뜬 곳: OpenAI 2건, HN 링크 2건(블로그·Telegraph), NYT 1건, WSJ 2건 → 그 기사는 앱 결과만으로 판정.
- 출처별 자세한 것: `mac/sources-audit/<출처id>.md`. 점검 도구: `mac/sources-audit/tools/intl2/`(아래 '다시 돌리는 법').

## 한 줄 결론

**BBC 4곳이 가장 급하다** — 새 BBC 기사 꼴(`data-block` 조각)에서 Readability 가 한 조각만 골라 **리드·앞 조각이 빠지고(34~95%) 본문 사진이 한 장도 안 온다**. 다음은 **Ars Technica 의 덩어리 나뉨(리드 덩어리 통째 빠짐)**, 그리고 여러 곳의 **기자 상자·구독/기부 권유·관련 목록 섞임**. NYT·WSJ 는 앱에서 사실상 못 읽고(차단), **The Verge 는 지금 구독 문이 있어 paywall 값이 틀림**.

## 출처별

| 출처 | 켜짐 | 판정 | 완전성 중앙값 | 주요 문제 | 제안 규칙 |
|---|---|---|---|---|---|
| [Ars Technica](ars.md) | 예 | 부분 | 49% | `.post-content` 여러 덩어리 → 리드 덩어리 빠짐(2/3건), 끝 기자 소개·댓글 수 | 모든 `.post-content` 이어 붙이기, 기자 상자 빼기 |
| [BBC Business](bbc-business.md) | 예 | 나쁨 | 65% | data-block 조각 중 하나만 → 리드·앞 조각 빠짐, 사진 0 | `[data-block]` 순서대로 걷기 또는 `__INITIAL_DATA__` |
| [BBC Science](bbc-science.md) | 예 | 나쁨 | 67% | 같은 조각 문제·사진 0, 영상 페이지에 바닥글 메뉴가 본문으로 | BBC 공용 + `/news/videos/` 는 noText |
| [BBC News](bbc-top.md) | 예 | 나쁨 | 85% | 중간·끝 조각 빠짐, 사진 0 | BBC 공용 |
| [Carbon Brief](carbonbrief.md) | 예 | 부분 | 98% | 끝 관련 글 사진 3~4장, 목차 단추 글 | 끝의 설명 없는 사진 줄 버리기, 목차 상자 빼기 |
| [Google DeepMind](deepmind.md) | 예 | 부분 | 97% | 날짜·분야 줄, 제목 반복, 저자 줄, 사진 대부분 빠짐 | 첫 블록 = 제목이면 빼기, 저자 줄 → 바이라인, 사진 꼴 확인 |
| [Guardian Culture](guardian-culture.md) | 예 | 좋음 | 88%(측정 탓, 실제 ≈100%) | 목록형 기사 소제목 1개 반복, 끝 정보 줄 1줄 | (선택) 연속 같은 소제목 하나로 |
| [Guardian World](guardian-world.md) | 예 | 부분 | 100% | 라이브 블로그: 기자 얼굴·이름·Key events·'double quotation mark' | 라이브 머리 상자·아이콘 대체 글 빼기 |
| [NVIDIA](nvidia.md) | 예 | 좋음 | 99% | 끝 구독·법적 고지 줄, 긴 목록 일부 빠짐 | 끝 고지 문단 빼기 |
| [OpenAI](openai.md) | 예 | 좋음 | 비교 불가(헤드리스 확인 화면) | 앱 결과 깨끗(소제목·인용·인용자 줄) | 피드 1,293건 — 받기 크기 확인 |
| [The Verge](verge.md) | 예 | 부분 | 비교 불가(구독 문) | **구독 문 있음(paywall 값 '-')**, 머리 기자 사진·소개, 끝 Follow 줄 | paywall → metered, 기자 상자 빼기 |
| [Al Jazeera](aljazeera.md) | 아니오 | 부분 | 91%(측정 탓, 실제 ≈100%) | 'Recommended Stories' 소제목+목록이 본문 중간에 | 추천 상자 빼기 |
| [BBC Technology](bbc-tech.md) | 아니오 | 나쁨 | 97% | BBC 공용 문제, 사진 없는 설명, 붙은 바이라인 줄, Sounds 오디오 = 메뉴 68개 | BBC 공용 + `/sounds/play/` noText |
| [ESPN](espn.md) | 아니오 | 부분 | 100% | 다른 기사 목록 줄·영상 제목·바이라인+날짜 li, 트윗 인용 중복, 팀 로고 | 머리 상자 빼기, 트윗 처리, 로고 isJunk |
| [Hacker News 1면](hn-front.md) | 아니오 | 부분 | 비교 불가(외부 원문) | 원문이 제각각, 웹앱 첫 화면은 메뉴 li 만 | 짧은 li 만이면 noText |
| [Inside Climate News](insideclimate.md) | 아니오 | 부분 | 99% | 끝 기부 권유 + 기자 상자(얼굴·이름·직함·소개) | 기부·기자 상자 빼기 |
| [NASA](nasa.md) | 아니오 | 좋음 | 95% | 보도자료 끝 연락처 줄, 사진 기사 메타 줄 | '-end-' 뒤 버리기, 메타 줄 빼기 |
| [NPR News](npr-news.md) | 아니오 | 부분 | 92%(측정 탓 일부) | 사진 설명·출처가 따로 문단, 소제목 일부 빠짐 | 사진 뒤 출처 문단 → cap |
| [NYT Arts](nyt-arts.md) | 아니오 | 나쁨(차단) | – | 앱 403 → 막힌 사이트, 사이트도 구독 문 | metered → hard(또는 learned 즉시) |
| [NYT Health](nyt-health.md) | 아니오 | 나쁨(차단) | – | 같음 | 같음 |
| [NYT World](nyt-world.md) | 아니오 | 나쁨(차단) | – | 같음, 영상 페이지 섞임 | 같음 + `/video/` noText |
| [ScienceDaily](sciencedaily.md) | 아니오 | 좋음 | 100% | 추적 픽셀(count.gif)이 사진으로 | 추적 픽셀 isJunk |
| [TechCrunch](techcrunch.md) | 아니오 | 부분 | 100% | 끝 제휴 고지·기자 소개·연락처·'View Bio' | 끝 고지·기자 카드 빼기 |
| [WIRED](wired.md) | 아니오 | 좋음 | 비교 불가(구독 문) | 앱은 전문, 사이트는 앞부분만(metered 맞음) | 유지(사진 꼴 재확인) |
| [WSJ Markets](wsj-markets.md) | 아니오 | 나쁨(차단) | – | 앱 401, hard 맞음 | 유지, 요약만 출처로 |

판정 수: 좋음 6 · 부분 11 · 나쁨 8(차단 4 포함).
완전성 = 사이트 본문 글 가운데 우리가 얻은 글의 비율(100% 상한). 사이트가 구독 문 뒤 일부만 보여 준 기사, 기사 아닌 페이지(300자 미만)는 뺌.

## 문제 종류별 출처 수

### 잘림(빠짐) 원인

| 원인 | 출처 수 | 출처 |
|---|---|---|
| 본문이 여러 덩어리로 나뉘어 Readability 가 하나만 고름 | 5 | bbc-business · bbc-science · bbc-top · bbc-tech · ars |
| 본문 사진 전부(또는 거의) 빠짐 | 6 | BBC 4곳 · deepmind · aljazeera |
| 차단(403/401)으로 본문 없음 | 4 | nyt-arts · nyt-health · nyt-world · wsj-markets |
| 영상·오디오·웹앱 페이지에서 메뉴가 본문으로(noText 안내가 맞음) | 3 | bbc-science(영상) · bbc-tech(Sounds) · hn-front(웹앱) |
| 긴 링크 목록 일부 잘림 | 1 | nvidia |

### 섞여 들어온 것

| 종류 | 출처 수 | 출처 |
|---|---|---|
| 기자 소개·기자 상자·기자 얼굴 사진 | 6 | verge · techcrunch · insideclimate · ars · guardian-world · espn(바이라인 li) |
| 관련 기사·추천 목록(사진 포함) | 3 | aljazeera · carbonbrief · espn |
| 구독·기부·뉴스레터·제휴 고지 | 4 | insideclimate · techcrunch · nvidia · verge(Follow) |
| 날짜·분야·제목 반복·메타 줄 | 3 | deepmind · nasa · espn |
| 사진 출처 줄이 설명과 분리 | 3 | npr-news · verge · bbc-tech(설명만 남음) |
| 바닥글·메뉴 | 3 | bbc-science · bbc-tech · hn-front |
| 아이콘 대체 글·라이브 블로그 머리 | 1 | guardian-world |
| 잡그림(추적 픽셀·팀 로고) | 2 | sciencedaily · espn |
| 연락처 줄(보도자료) | 1 | nasa |
| 댓글 수 | 1 | ars |

### 유료 표시

| 출처 | 지금 값 | 관찰 | 제안 |
|---|---|---|---|
| The Verge | `-` | 구독 문(Zephr)·isAccessibleForFree=false. 앱은 서버 HTML 에서 전문을 얻음 | **metered** |
| NYT Arts·Health·World | metered | 앱은 403 으로 한 건도 못 읽음, 사이트도 구독 문 | **hard** 또는 처음부터 'learned'(열기 전 다른 보도 권하기) |
| WIRED | metered | 사이트는 앞부분만, 앱은 전문 | 유지 |
| WSJ Markets | hard | 앱 401, 사이트 구독 문·확인 화면 | 유지 |
| HN 링크(Telegraph 등) | – | 도메인별 knownDomains 로 표시 | 카드에 뜨는지 확인 |

틀린 값 1곳(Verge), 실제보다 약한 값 3곳(NYT).

### 번역(구조로 본 위험만 — 자세한 것은 작업자 Translate)

- 군더더기가 번역되어 기사 일부처럼 보임: verge(첫 문단 = 기자 소개), techcrunch·insideclimate(끝 고지·기부), aljazeera(본문 중간 추천 목록).
- 'double quotation mark' 아이콘 글이 인용마다 붙음: guardian-world.
- 메뉴 낱말 수십 개 번역: bbc-science 영상 · bbc-tech Sounds.
- 블록이 아주 많음(608개, li 수백): carbonbrief 인터랙티브 — 번역 시간·비용.
- 원문 남음·문단 어긋남은 이번에 번역을 돌리지 않아 판단하지 않음.

## 함께 쓰는 사람에게

- **Reader(reader-cut)**: 가장 효과 큰 일은 ① BBC `[data-block]` 걷기(4곳·사진 포함) ② "같은 부모 아래 같은 class 본문 형제 합치기"(Ars, 다른 WordPress·Arc 사이트에도 효과 가능) ③ 끝부분 군더더기 일반 규칙(기자 소개·연락처·'View Bio'·'Follow topics'·제휴 고지·기부 권유·'Recommended Stories') ④ noText 판정(블록이 모두 짧은 li·바닥글이면 실패 안내) ⑤ ImageKey.isJunk 추가(추적 픽셀·팀 로고·라이브 블로그 기자 얼굴).
- **Translate(translate-quality)**: 위 '번역' 목록의 출처를 표본으로.
- 기사 전체 주소: 저장소 밖 `newsletter-wt/srcaudit-shots/intl2/urls.tsv`(md 에는 이름이 든 slug 를 지운 짧은 주소만). 스크린샷도 같은 폴더(`<id>-1~3.png`).

## 다시 돌리는 법

```sh
T=mac/sources-audit/tools/intl2; W=$(mktemp -d)
python3 -I $T/feeds.py <출처 목록.tsv> $W                 # 피드 관찰 + 출처마다 3건 고르기 → feeds.json · replay.json
git apply $T/readsweep-dump.patch                          # (커밋하지 않음) ReadSweep 이 블록 목록·숨김 번호를 json 에 함께 쓰게
cd mac && bugak run --heavy -- swift build && cd ..
DROPCAP_DATA_DIR=$W/data DROPCAP_TEST_READSWEEP=$W DROPCAP_TEST_READSWEEP_LABEL=intl2 \
  DROPCAP_TEST_READSWEEP_REPLAY=$W/replay.json mac/.build/debug/Dropcap   # 앱 창 없이 돌고 끝나면 닫힘
git checkout mac/Sources/Dropcap/Reader/ReadSweep.swift
PW=<playwright 모듈> CHROME=<chrome-headless-shell> node $T/site.cjs $W/replay.json $W/site.json <스크린샷 폴더>
python3 -I $T/compare.py $W && python3 -I $T/report.py $W mac/sources-audit <주소 목록 파일>
```

- 측정 한계: 사이트 본문 영역은 알려진 본문 선택자 → 없으면 '긴 문단 글자의 80% 를 담는 가장 깊은 요소'로 고르고, 끝없이 이어 붙이는 사이트는 첫 `<article>` 안으로 좁힘. 드롭캡(가디언)·영역 안 관련 목록(알자지라·NPR)은 '빠진 것'으로 잘못 잡힐 수 있어 md 관찰에 적어 둠.
