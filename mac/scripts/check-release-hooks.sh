#!/bin/bash
# 배포 빌드에 시험 장치가 남았는지 본다(보안 점검 M9).
#   scripts/check-release-hooks.sh            -c release 로 빌드한 뒤 확인
#   scripts/check-release-hooks.sh <실행 파일>  이미 만든 실행 파일을 확인(예: .build/debug/Dropcap 은 실패해야 정상)
# 시험용 환경 변수·시나리오 시험(E2E*)·시험 훅·시험 서버 허용 스위치의 이름이 하나라도 보이면 실패.
# 이름 규칙: 접두어로 묶어 새 장치를 목록에 더하지 않아도 잡는다
#   - E2E 로 시작하는 이름(E2ERunner·E2ESoak·E2EFaults·E2EProbe… — 배포에 남는 E2EOff 도 이름은 남지 않음)
#   - DROPCAP_ 로 시작하는 환경 변수 중 배포에서도 읽는 것(아래 KEEP) 밖의 모든 것(DROPCAP_TEST_·DROPCAP_FAULTS_·DROPCAP_PROBE_·DROPCAP_SOAK_…)
#   - 접두어가 없는 시험 장치 이름(NAMES)
set -uo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  (cd "$MAC" && swift build -c release --product Dropcap) || exit 1
  BIN="$MAC/.build/release/Dropcap"
fi
[[ -f "$BIN" ]] || { echo "실행 파일이 없습니다: $BIN"; exit 1; }
KEEP="DROPCAP_DATA_DIR DROPCAP_DEBUG_DRIP DROPCAP_DEBUG_EXTRACT" # 배포에도 있는 스위치(자료 폴더 바꾸기·진단 출력) — 시험 장치가 아님
NAMES="ReaderSaveTestHooks ExtrasTestHooks DesignTestHooks ReadSweep PerfHarness SectionIconLab allowLocalForTests"
STR="$(strings -a "$BIN")"
fail=0
while read -r n name; do
  [[ -z "$name" ]] && continue
  [[ " $KEEP " == *" $name "* ]] && continue
  echo "남음: $name ($n)"; fail=1
done < <(grep -oE 'E2E[A-Za-z0-9_]+|DROPCAP_[A-Z0-9_]+' <<<"$STR" | sort | uniq -c)
for pat in $NAMES; do
  n=$(grep -c -- "$pat" <<<"$STR")
  if [[ "$n" -gt 0 ]]; then echo "남음: $pat ($n)"; fail=1; fi
done
if [[ $fail -eq 0 ]]; then echo "통과: 배포 빌드에 시험 장치 없음 ($BIN)"; else echo "실패: 배포 빌드에 시험 장치가 남았습니다"; fi
exit $fail
