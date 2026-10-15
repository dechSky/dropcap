# 출처 점검 KR2 도구

`_KR2.md`·`<출처>.md` 를 만든 스크립트. 기사 본문·스크린샷은 저장소 밖(scratchpad·srcaudit-shots)에만 두고, 저장소에는 숫자와 사람이 본 메모만 남긴다.

| 파일 | 하는 일 |
|---|---|
| `feedinfo.py` | 출처마다 피드 1회: 요약·전문 길이, HTML 여부, 사진 위치·크기 표시, 날짜·분야·기자 칸, 링크 꼴(308 따라가기·맨 & 너그럽게) |
| `readsweep-dump.patch` | 앱 `Reader/ReadSweep.swift` 임시 고침(커밋하지 않음): 추린 블록 전부와 피드 요약을 json 에 남기고, `DROPCAP_TEST_READSWEEP_COLLECT_ONLY=1` 이면 기사 목록만 쓰고 끝, `_ONLY` 출처만 피드를 받음 |
| `sitemeasure.js` | 헤드리스 Chromium(화면·포커스 안 씀)으로 같은 기사를 열어 출처별 본문 상자를 잼. 요청 사이 1.5초 |
| `compare.py` | 앱 블록(읽기 창이 숨기는 블록을 뺀 것)과 사이트 본문을 맞대어 기사마다 숫자로 → `compare-2026-10-15.json` |
| `render.py` | `compare-*.json` + `notes.json`(사람이 본 메모·판정·규칙) → md |

## 다시 돌리는 법

```sh
cd mac && git apply sources-audit/tools/kr2/readsweep-dump.patch && swift build
W=<저장소 밖 작업 폴더>; IDS=<출처 id,…>
python3 -I sources-audit/tools/kr2/feedinfo.py <목록.tsv> $W/feedinfo.json
DROPCAP_DATA_DIR=$W/data DROPCAP_TEST_READSWEEP=$W DROPCAP_TEST_READSWEEP_LABEL=cand DROPCAP_TEST_READSWEEP_N=10 \
  DROPCAP_TEST_READSWEEP_ONLY=$IDS DROPCAP_TEST_READSWEEP_COLLECT_ONLY=1 .build/debug/Dropcap
# targets-cand.json 에서 출처마다 3건을 골라 targets-pick.json(출처를 돌아가며 놓기)
DROPCAP_DATA_DIR=$W/data DROPCAP_TEST_READSWEEP=$W DROPCAP_TEST_READSWEEP_LABEL=kr2 \
  DROPCAP_TEST_READSWEEP_REPLAY=$W/targets-pick.json .build/debug/Dropcap
NODE_PATH=<playwright 가 있는 node_modules> node sources-audit/tools/kr2/sitemeasure.js $W/targets-pick.json $W/site.json <스크린샷 폴더>
python3 -I sources-audit/tools/kr2/compare.py $W/sweep-kr2.json $W/site.json $W/feedinfo.json sources-audit/tools/kr2/compare-2026-10-15.json
python3 -I sources-audit/tools/kr2/render.py <목록.tsv> sources-audit/tools/kr2/compare-2026-10-15.json sources-audit/tools/kr2/notes.json sources-audit
git checkout Sources/Dropcap/Reader/ReadSweep.swift
```

목록.tsv 꼴: `id<TAB>이름<TAB>종류<TAB>기본켜짐|-<TAB>paywall|-<TAB>피드 주소`.

## 한계

- 사이트 '본문 상자'는 출처별 선택자(없으면 문단 밀도)로 고른다. 영상·만화·속보처럼 글이 거의 없는 페이지는 상자를 못 찾아 '사이트 못 잼'으로 적고 스크린샷으로 확인했다.
- 문단 대조는 줄 앞 25자 일치로 본다. 본문 상자 안 네이티브 광고 제목(로또·건강 광고 등)은 빼고 센다.
- 섞임 종류는 낱말 규칙이라 본문 낱말에 걸리는 오탐이 있다(예: 본문의 '구독형 OTT') — 그런 것은 notes.json 의 `ignore` 로 뺐다.
