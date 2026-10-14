#!/bin/zsh
# 사용자 흐름 시나리오 시험(끝에서 끝까지). 실제 기록·네트워크를 쓰지 않는다.
#   mac/scripts/e2e/run.sh [결과 폴더]
# - 앱은 임시 DROPCAP_DATA_DIR 로, 견본 피드(E2EFeeds)로만 돈다.
# - 시계: fakeclock.dylib 를 이 실행에만 끼워 하루치(묶음 시각·하루 상한·36시간)를 몇 분 안에 본다.
# - 세 번 띄운다: main(1~11단계) → restart(12-가: 다시 시작해 상태 유지) → recover(12-나: 상태 파일·DB 를 깨뜨린 뒤 복구)
# 결과: <결과 폴더>/results-*.json · e2e.log · shots/*.png · feeds/ · E2E-run.md
set -u
MAC=${0:A:h:h:h}
OUT=${1:-$MAC/.build/e2e/$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:A}
mkdir -p "$OUT/shots"
DATA=$(mktemp -d "${TMPDIR:-/tmp}/dropcap-e2e-data.XXXXXX")
echo "결과: $OUT"
echo "데이터(임시): $DATA"

clang -dynamiclib -o "$OUT/fakeclock.dylib" "$MAC/scripts/e2e/fakeclock.c" || exit 1
if [[ -z "${E2E_SKIP_BUILD:-}" ]]; then
  (cd "$MAC" && swift build) || exit 1
fi
BIN="$MAC/.build/debug/Dropcap"
rm -f "$OUT/clock-offset"

# 한 단계 실행: 앱이 스스로 끝나기를 기다리되, 너무 오래 걸리면 끈다
run_phase() {
  local phase=$1 limit=$2
  echo "== $phase (최대 ${limit}초)"
  DROPCAP_DATA_DIR="$DATA" DROPCAP_TEST_E2E="$OUT" DROPCAP_TEST_E2E_PHASE="$phase" DROPCAP_TEST_ONBOARD=1 \
  DROPCAP_CLOCK_FILE="$OUT/clock-offset" DYLD_INSERT_LIBRARIES="$OUT/fakeclock.dylib" \
    "$BIN" >>"$OUT/app-$phase.log" 2>&1 &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    sleep 2; waited=$((waited + 2))
    if (( waited >= limit )); then
      echo "   시간 초과 — 끕니다"; kill $pid; sleep 2; kill -9 $pid 2>/dev/null
      echo "{\"phase\":\"$phase\",\"timeout\":true}" > "$OUT/results-$phase-timeout.json"
      break
    fi
  done
  wait $pid 2>/dev/null
  echo "   앱 끝남: 종료 코드 $?" | tee -a "$OUT/app-$phase.log"
}

run_phase main 900
run_phase restart 180

# 12-나: 상태 파일과 매거진 DB 를 깨뜨린다(앱이 꺼진 상태에서)
cp "$DATA/native-state.json" "$OUT/native-state.before-corrupt.json" 2>/dev/null
printf '{"seen": {"broken' > "$DATA/native-state.json"
head -c 8192 /dev/urandom > "$DATA/magazine.sqlite"
# WAL 에 쪽이 다 남아 있으면 SQLite 는 본 파일이 깨져도 WAL 로 읽어 버린다 → WAL·SHM 도 함께 깨뜨려 실제 손상처럼
for ext in -wal -shm; do [[ -f "$DATA/magazine.sqlite$ext" ]] && head -c 4096 /dev/urandom > "$DATA/magazine.sqlite$ext"; done
echo "== 상태 파일·DB 를 깨뜨림"
run_phase recover 180

ls "$DATA" > "$OUT/data-dir-listing.txt"
echo "임시 데이터 폴더는 남겨 둠(검토 후 지워도 됨): $DATA"
ls "$OUT"/results-*.json
