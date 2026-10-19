#!/bin/zsh
# 실패 처리 시험. 실제 기록·네트워크를 쓰지 않는다(임시 데이터 · 견본 피드 · 시험 시계).
#   mac/scripts/e2e/faults.sh [결과 폴더]
# 데이터 폴더를 64MB 짜리 디스크 이미지(Finder 에 안 보이게 붙임)에 두어 '디스크 가득'까지 본다. 붙이지 못하면 그 단계만 건너뜀.
set -u
MAC=${0:A:h:h:h}
OUT=${1:-$MAC/.build/e2e/faults-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:A}
mkdir -p "$OUT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dropcap-faults.XXXXXX")
MNT="$TMP/vol"
FULL=""
mkdir -p "$MNT"
if hdiutil create -quiet -size 64m -fs HFS+ -volname DropcapFaults "$TMP/vol.dmg" && hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$TMP/vol.dmg"; then
  DATA="$MNT/data"; FULL=1
else
  DATA="$TMP/data"
fi
mkdir -p "$DATA"
echo "결과: $OUT"
echo "데이터(임시): $DATA ${FULL:+(64MB 볼륨)}"

clang -dynamiclib -o "$OUT/fakeclock.dylib" "$MAC/scripts/e2e/fakeclock.c" || exit 1
if [[ -z "${E2E_SKIP_BUILD:-}" ]]; then
  (cd "$MAC" && swift build) || exit 1
fi
BIN="$MAC/.build/debug/Dropcap"
rm -f "$OUT/clock-offset"

env DROPCAP_DATA_DIR="$DATA" DROPCAP_TEST_E2E="$OUT" DROPCAP_TEST_E2E_PHASE=faults DROPCAP_TEST_ONBOARD=1 ${FULL:+DROPCAP_FAULTS_FULLDISK=1} \
  DROPCAP_CLOCK_FILE="$OUT/clock-offset" DYLD_INSERT_LIBRARIES="$OUT/fakeclock.dylib" \
  "$BIN" >>"$OUT/app-faults.log" 2>&1 &
PID=$!
waited=0
while kill -0 $PID 2>/dev/null; do
  sleep 2; waited=$((waited + 2))
  if (( waited >= 900 )); then echo "시간 초과 — 끕니다"; kill $PID; sleep 2; kill -9 $PID 2>/dev/null; break; fi
done
wait $PID 2>/dev/null
CODE=$?
echo "앱 끝남: 종료 코드 $CODE" | tee -a "$OUT/app-faults.log"
ls -la "$DATA" > "$OUT/data-dir-listing.txt" 2>&1
[[ -n "$FULL" ]] && hdiutil detach -quiet "$MNT"
rm -rf "$TMP"
python3 - "$OUT/results-faults.json" <<'PY'
import json, sys
try: steps = json.load(open(sys.argv[1]))
except Exception as e: print("결과 없음:", e); sys.exit(1)
for s in steps: print(("통과" if s.get("pass") else "실패" if s.get("pass") is False else "확인 못 함"), s["id"], s["title"], "—", s["actual"])
sys.exit(0 if all(s.get("pass") is not False for s in steps) else 1)
PY
