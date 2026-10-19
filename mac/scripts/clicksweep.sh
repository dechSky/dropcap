#!/bin/zsh
# 화면 단추 하나하나 클릭 시험. 임시 데이터 폴더·견본 피드로 앱을 한 번 띄워
# 분야 고르기·상단바 화면·매거진(기본·최소 × 위·아래, 지면들)·읽기 창·설정 탭·물방울의 누를 것을 모두 확인한다.
#
#   mac/scripts/clicksweep.sh [--real] [--idle 분] [결과 폴더]
#     기본(조용한 모드): 앱을 앞으로 띄우지 않고 커서도 옮기지 않는다. 창은 투명·마우스 통과·화면 밖.
#                       단추마다 ① 여러 점 맞음 검사(손쉬운 사용 hitTest) ② 손쉬운 사용 '누름'으로 동작 확인.
#                       사용자가 이 Mac 을 쓰는 중에도 돌려도 된다.
#     --real            진짜 마우스 이벤트(앱 활성화). 마지막 입력이 --idle 분(기본 3) 넘었을 때만 누르고,
#                       사용자 입력이 생기면 앱을 숨기고 다시 한가해질 때까지 기다린다. 진짜 커서 이동은 DROPCAP_TEST_WARP=1 일 때만.
#   DROPCAP_CLICK_ONLY=onboard,menu,magazine,reader,settings,toast 로 일부만.
# 결과: <결과 폴더>/CLICKS-run.md · results-clicks.json · ax-*.txt · blocked-activations.txt(막은 활성화 시도) · shots/click-fail-*.png
set -u
MAC=${0:A:h:h}
REAL=""; IDLE=3
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --real) REAL=1; shift ;;
    --idle) IDLE=$2; shift 2 ;;
    *) echo "모르는 옵션 $1"; exit 2 ;;
  esac
done
OUT=${1:-$MAC/.build/clicks/$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:A}
mkdir -p "$OUT/shots"
DATA=$(mktemp -d "${TMPDIR:-/tmp}/dropcap-clicks-data.XXXXXX")
echo "결과: $OUT · 데이터(임시): $DATA · 모드: ${REAL:+실제 클릭(한가할 때만, ${IDLE}분)}${REAL:-조용한(포커스 없음)}"
if [[ -z "${E2E_SKIP_BUILD:-}" ]]; then (cd "$MAC" && swift build) || exit 1; fi
typeset -a extra
[[ -n "$REAL" ]] && extra=(DROPCAP_TEST_REAL_UI=1 DROPCAP_CLICK_IDLE_MIN=$IDLE)
env "${extra[@]}" DROPCAP_DATA_DIR="$DATA" DROPCAP_TEST_E2E="$OUT" DROPCAP_TEST_E2E_PHASE=clicks DROPCAP_TEST_ONBOARD=1 \
  DROPCAP_TEST_LOG="$OUT/testlog.txt" "$MAC/.build/debug/Dropcap" >>"$OUT/app-clicks.log" 2>&1 &
pid=$! waited=0
while kill -0 $pid 2>/dev/null; do
  sleep 5; waited=$((waited + 5))
  if (( waited >= ${CLICK_LIMIT:-5400} )); then echo "시간 초과 — 끕니다"; kill $pid; sleep 2; kill -9 $pid 2>/dev/null; break; fi
done
wait $pid 2>/dev/null; echo "앱 끝남: 종료 코드 $?"
tail -1 "$OUT/CLICKS-run.md" 2>/dev/null
grep "\[앞 앱\]" "$OUT/testlog.txt" 2>/dev/null | tail -3
