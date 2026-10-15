#!/bin/zsh
# 창 머리 겹침 스냅샷(조용한 모드 — 앱을 앞으로 띄우지 않음): 분야 고르기·매거진(오늘·분야·스토리) × 밝게·어둡게 × 맨 위·스크롤
#   mac/scripts/e2e/header.sh [결과 폴더]      결과: <결과 폴더>/shots/header-*.png · app-header.log
set -u
MAC=${0:A:h:h:h}
OUT=${1:-$MAC/.build/e2e/header-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:A}
mkdir -p "$OUT/shots"
DATA=$(mktemp -d "${TMPDIR:-/tmp}/dropcap-header-data.XXXXXX")
if [[ -z "${E2E_SKIP_BUILD:-}" ]]; then (cd "$MAC" && swift build) || exit 1; fi
echo "결과: $OUT"
DROPCAP_DATA_DIR="$DATA" DROPCAP_TEST_E2E="$OUT" DROPCAP_TEST_E2E_PHASE=header DROPCAP_TEST_ONBOARD=1 \
  "$MAC/.build/debug/Dropcap" >>"$OUT/app-header.log" 2>&1 &
pid=$! waited=0
while kill -0 $pid 2>/dev/null; do
  sleep 2; waited=$((waited + 2))
  (( waited >= 300 )) && { echo "시간 초과 — 끕니다"; kill $pid; break; }
done
wait $pid 2>/dev/null; echo "앱 끝남: 종료 코드 $?"
rm -rf "$DATA"
ls "$OUT/shots"
