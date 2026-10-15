#!/bin/bash
# 배포 빌드에 시험 장치가 남았는지 본다(보안 점검 M9).
#   scripts/check-release-hooks.sh            -c release 로 빌드한 뒤 확인
#   scripts/check-release-hooks.sh <실행 파일>  이미 만든 실행 파일을 확인(예: .build/debug/Dropcap 은 실패해야 정상)
# 시험용 환경 변수(DROPCAP_TEST_*)·시나리오 시험(E2E*)·시험 훅·시험 서버 허용 스위치의 이름이 하나라도 보이면 실패.
set -uo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  (cd "$MAC" && swift build -c release --product Dropcap) || exit 1
  BIN="$MAC/.build/release/Dropcap"
fi
[[ -f "$BIN" ]] || { echo "실행 파일이 없습니다: $BIN"; exit 1; }
fail=0
for pat in DROPCAP_TEST_ E2ERunner E2EClickSweep E2EQuietUI ReaderSaveTestHooks ExtrasTestHooks ReadSweep PerfHarness SectionIconLab allowLocalForTests; do
  n=$(strings -a "$BIN" | grep -c -- "$pat")
  if [[ "$n" -gt 0 ]]; then echo "남음: $pat ($n)"; fail=1; fi
done
if [[ $fail -eq 0 ]]; then echo "통과: 배포 빌드에 시험 장치 없음 ($BIN)"; else echo "실패: 배포 빌드에 시험 장치가 남았습니다"; fi
exit $fail
