#!/bin/zsh
# 설정 효과 시험: 설정을 바꾸면 실제 동작이 바뀌는지. 실제 기록·네트워크를 쓰지 않는다(임시 데이터 · 견본 피드).
#   mac/scripts/e2e/settings.sh [결과 폴더]
# 조용한 모드(E2EQuietUI): 앱을 앞으로 띄우지 않고 창·물방울은 투명·마우스 통과.
set -u
MAC=${0:A:h:h:h}
OUT=${1:-$MAC/.build/e2e/settings-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:A}
mkdir -p "$OUT/shots"
DATA=$(mktemp -d "${TMPDIR:-/tmp}/dropcap-settings.XXXXXX")
echo "결과: $OUT"
echo "데이터(임시): $DATA"

clang -dynamiclib -o "$OUT/fakeclock.dylib" "$MAC/scripts/e2e/fakeclock.c" || exit 1
if [[ -z "${E2E_SKIP_BUILD:-}" ]]; then
  (cd "$MAC" && swift build) || exit 1
fi
BIN="$MAC/.build/debug/Dropcap"
rm -f "$OUT/clock-offset"

env DROPCAP_DATA_DIR="$DATA" DROPCAP_TEST_E2E="$OUT" DROPCAP_TEST_E2E_PHASE=settings DROPCAP_TEST_ONBOARD=1 \
  DROPCAP_CLOCK_FILE="$OUT/clock-offset" DYLD_INSERT_LIBRARIES="$OUT/fakeclock.dylib" \
  "$BIN" >>"$OUT/app-settings.log" 2>&1 &
PID=$!
waited=0
while kill -0 $PID 2>/dev/null; do
  sleep 2; waited=$((waited + 2))
  if (( waited >= 600 )); then echo "시간 초과 — 끕니다"; kill $PID; sleep 2; kill -9 $PID 2>/dev/null; break; fi
done
wait $PID 2>/dev/null
echo "앱 끝남: 종료 코드 $?" | tee -a "$OUT/app-settings.log"
rm -rf "$DATA"
python3 - "$OUT/results-settings.json" <<'PY'
import json, sys
try: steps = json.load(open(sys.argv[1]))
except Exception as e: print("결과 없음:", e); sys.exit(1)
for s in steps: print(("통과" if s.get("pass") else "실패" if s.get("pass") is False else "확인 못 함"), s["id"], s["title"], "—", s["actual"])
sys.exit(0 if all(s.get("pass") is not False for s in steps) else 1)
PY
