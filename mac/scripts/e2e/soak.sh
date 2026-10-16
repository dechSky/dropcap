#!/bin/zsh
# 오래 켜 두기 시험(soak, mac/STABILITY.md). 실제 기록·네트워크를 쓰지 않는다(임시 DROPCAP_DATA_DIR · 견본 피드 · 시험 시계).
#   mac/scripts/e2e/soak.sh [결과 폴더]        환경: SOAK_DAYS(3) SOAK_STEP_MIN(10) SOAK_POSTS(20) E2E_SKIP_BUILD
# 결과: soak.jsonl(시험 1시간마다 지표) · leaks.txt · footprint.txt · vmmap.txt · e2e.log · app-soak.log
set -u
MAC=${0:A:h:h:h}
OUT=${1:-$MAC/.build/e2e/soak-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:A}
mkdir -p "$OUT"
DATA=${SOAK_DATA:-$(mktemp -d "${TMPDIR:-/tmp}/dropcap-soak-data.XXXXXX")}
echo "결과: $OUT"
echo "데이터(임시): $DATA"

clang -dynamiclib -o "$OUT/fakeclock.dylib" "$MAC/scripts/e2e/fakeclock.c" || exit 1
if [[ -z "${E2E_SKIP_BUILD:-}" ]]; then
  (cd "$MAC" && swift build) || exit 1
fi
BIN="$MAC/.build/debug/Dropcap"
rm -f "$OUT/clock-offset" "$OUT/soak-ready" "$OUT/soak-done"

DROPCAP_DATA_DIR="$DATA" DROPCAP_TEST_E2E="$OUT" DROPCAP_TEST_E2E_PHASE=soak DROPCAP_TEST_ONBOARD=1 \
DROPCAP_SOAK_DAYS=${SOAK_DAYS:-3} DROPCAP_SOAK_STEP_MIN=${SOAK_STEP_MIN:-10} DROPCAP_SOAK_POSTS=${SOAK_POSTS:-20} \
DROPCAP_CLOCK_FILE="$OUT/clock-offset" DYLD_INSERT_LIBRARIES="$OUT/fakeclock.dylib" \
  "$BIN" >>"$OUT/app-soak.log" 2>&1 &
PID=$!
LIMIT=${SOAK_LIMIT:-7200}
waited=0
while kill -0 $PID 2>/dev/null; do
  if [[ -f "$OUT/soak-ready" ]]; then
    echo "== 끝 무렵 측정(leaks·footprint·vmmap)"
    leaks $PID > "$OUT/leaks.txt" 2>&1
    footprint $PID > "$OUT/footprint.txt" 2>&1
    vmmap --summary $PID > "$OUT/vmmap.txt" 2>&1
    lsof -p $PID > "$OUT/lsof.txt" 2>&1
    heap -s $PID > "$OUT/heap.txt" 2>&1
    touch "$OUT/soak-done"
    rm -f "$OUT/soak-ready"
  fi
  sleep 5; waited=$((waited + 5))
  if (( waited >= LIMIT )); then echo "시간 초과 — 끕니다"; kill $PID; sleep 2; kill -9 $PID 2>/dev/null; break; fi
done
wait $PID 2>/dev/null
echo "앱 끝남: 종료 코드 $?" | tee -a "$OUT/app-soak.log"
ls -la "$DATA" > "$OUT/data-dir-listing.txt"
grep -E "leaks for|total leaked" "$OUT/leaks.txt" 2>/dev/null
echo "임시 데이터 폴더(검토 후 지워도 됨): $DATA"
