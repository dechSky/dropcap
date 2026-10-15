#!/bin/sh
# KR1Probe.swift 를 시험 폴더에 잠깐 복사해 돌리고 지운다(앱 코드·시험은 고치지 않음).
# 쓰기: sh run-probe.sh <feeds.json> <결과 폴더> [출처 id,…]
set -e
HERE=$(cd "$(dirname "$0")" && pwd); MAC=$(cd "$HERE/../../.." && pwd)
cp "$HERE/KR1Probe.swift" "$MAC/Tests/DropcapTests/KR1Probe.swift"
trap 'rm -f "$MAC/Tests/DropcapTests/KR1Probe.swift"' EXIT
cd "$MAC" && KR1_FEEDS="$1" KR1_OUT="$2" KR1_ONLY="$3" DROPCAP_DATA_DIR=$(mktemp -d) swift test --filter KR1Probe
