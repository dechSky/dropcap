#!/bin/zsh
# 시작 시간·첫 화면 재기. 실제 기록·네트워크를 쓰지 않는다(임시 데이터 · 견본 피드).
#   mac/scripts/e2e/startup.sh <큰 데이터 폴더(오래 켜 두기 시험이 남긴 것)> [결과 폴더] [시계 오프셋 파일]
# 두 경우를 각 두 번: 빈 데이터(처음 실행) · 큰 데이터(사본 — 기본 출처 147곳 모두 켬). 큰 데이터는 매거진을 여는 동안 sample 을 뜬다.
set -u
MAC=${0:A:h:h:h}
BIG=${1:?큰 데이터 폴더}
OUT=${2:-$MAC/.build/e2e/startup-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:A}
CLOCK=${3:-}
mkdir -p "$OUT"
clang -dynamiclib -o "$OUT/fakeclock.dylib" "$MAC/scripts/e2e/fakeclock.c" || exit 1
if [[ -z "${E2E_SKIP_BUILD:-}" ]]; then (cd "$MAC" && swift build) || exit 1; fi
BIN="$MAC/.build/debug/Dropcap"

probe() { # 이름 데이터폴더
  local name=$1 data=$2
  echo "== $name"
  [[ -n "$CLOCK" ]] && cp "$CLOCK" "$OUT/clock-offset" || echo 0 > "$OUT/clock-offset"
  DROPCAP_DATA_DIR="$data" DROPCAP_TEST_E2E="$OUT" DROPCAP_TEST_E2E_PHASE=probe DROPCAP_PROBE_NAME="$name" \
  DROPCAP_CLOCK_FILE="$OUT/clock-offset" DYLD_INSERT_LIBRARIES="$OUT/fakeclock.dylib" \
    "$BIN" >>"$OUT/app-$name.log" 2>&1 &
  local pid=$! waited=0 sampled=""
  while kill -0 $pid 2>/dev/null; do
    if [[ -z "$sampled" && -f "$OUT/probe-sample" ]]; then sampled=1; sample $pid 13 -file "$OUT/sample-$name.txt" >/dev/null 2>&1 & fi
    sleep 0.5; waited=$((waited + 1))
    if (( waited >= 600 )); then echo "시간 초과"; kill $pid; sleep 1; kill -9 $pid 2>/dev/null; break; fi
  done
  wait $pid 2>/dev/null
  cat "$OUT/probe-$name.json" 2>/dev/null
}

for i in 1 2; do
  EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/dropcap-start-empty.XXXXXX")
  CLOCK_SAVED=$CLOCK; CLOCK=""
  probe "empty-$i" "$EMPTY"
  CLOCK=$CLOCK_SAVED
  rm -rf "$EMPTY"
done
COPY=$(mktemp -d "${TMPDIR:-/tmp}/dropcap-start-big.XXXXXX")
cp -R "$BIG"/. "$COPY"/
rm -f "$COPY/native.lock"
# 기본 출처 147곳을 모두 켠다
python3 - "$COPY/native-state.json" "$MAC/../shared/sources.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); src = json.load(open(sys.argv[2]))
src = src["sources"] if isinstance(src, dict) else src
for s in src: st.setdefault("enabled", {})[s["id"]] = True
json.dump(st, open(sys.argv[1], "w"))
print("켠 출처", sum(1 for v in st["enabled"].values() if v))
PY
for i in 1 2; do probe "big-$i" "$COPY"; done
rm -rf "$COPY"
