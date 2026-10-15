#!/bin/sh
# AddProbe.swift 를 시험 폴더에 잠깐 복사해 돌리고 지운다(앱 코드·시험은 고치지 않음).
# 쓰기: sh run-probe.sh <출처 id,…> <결과 폴더>
set -e
HERE=$(cd "$(dirname "$0")" && pwd); MAC=$(cd "$HERE/../../.." && pwd)
cp "$HERE/AddProbe.swift" "$MAC/Tests/DropcapTests/AddProbe.swift"
trap 'rm -f "$MAC/Tests/DropcapTests/AddProbe.swift"' EXIT
cd "$MAC" && ADD_IDS="$1" ADD_OUT="$2" DROPCAP_DATA_DIR=$(mktemp -d) swift test --filter AddProbe
