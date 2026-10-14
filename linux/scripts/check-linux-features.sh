#!/usr/bin/env bash
# 맥(리눅스 라이브러리 없음)에서 리눅스 전용 기능까지 형 검사만 한다(링크하지 않음).
# system-deps 에 "라이브러리는 있다고 치라"고 알려 pkg-config 를 건너뛴다. 실행 파일은 만들지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."
for k in LIBSOUP_3_0 JAVASCRIPTCOREGTK_6_0 WEBKITGTK_6_0 GTK4_LAYER_SHELL_0; do
  export SYSTEM_DEPS_${k}_NO_PKG_CONFIG=1 SYSTEM_DEPS_${k}_LIB=dummy
done
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-target-check} cargo check -p dropcap-gtk --features linux "$@"
