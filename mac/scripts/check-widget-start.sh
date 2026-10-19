#!/bin/bash
# 위젯 확장이 시작 단계에서 죽지 않는지 본다(mac-crash-fix).
#   scripts/check-widget-start.sh [DropcapWidgets.appex 경로]   기본: build/Dropcap.app 안의 것
# 확장 실행 파일을 직접 띄우면, 입구가 맞으면 'An XPC Service cannot be run directly.' 로 끝나고(정상),
# 입구가 틀리면 ExtensionFoundation 안에서 SIGTRAP(종료 133)으로 죽는다. 화면에 아무것도 띄우지 않는다.
set -uo pipefail
MAC="$(cd "$(dirname "$0")/.." && pwd)"
APPEX="${1:-$MAC/build/Dropcap.app/Contents/PlugIns/DropcapWidgets.appex}"
BIN="$APPEX/Contents/MacOS/DropcapWidgets"
[[ -x "$BIN" ]] || { echo "실행 파일이 없습니다: $BIN"; exit 1; }
out=$("$BIN" 2>&1 & p=$!; sleep 5; kill $p 2>/dev/null; wait $p 2>/dev/null; echo "종료=$?")
if grep -q "cannot be run directly" <<<"$out"; then echo "통과: 위젯 확장 입구 정상"; exit 0; fi
echo "실패: 위젯 확장이 시작 중 죽음 — $out" | tr '\n' ' '; echo; exit 1
