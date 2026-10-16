#!/bin/bash
# 본문 추출 스크립트(Dropcap.Ui/web/extract.js) 시험: 머리 없는 Chromium(WebView2 와 같은 엔진)에서 실제 꼴 HTML 로 돌린다.
# 저장소에 의존성을 넣지 않게 playwright-core 는 사용자 캐시 폴더에 받고(한 번), 브라우저는 Playwright 캐시의 것을 쓴다
# (없으면: npx playwright install chromium-headless-shell). 창을 띄우지 않는다.
# 쓰기: windows/scripts/test-extract.sh [dotnet test 인자…]
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${DROPCAP_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dropcap-test}"
if [ ! -d "$CACHE/node_modules/playwright-core" ]; then
  mkdir -p "$CACHE"
  (cd "$CACHE" && npm init -y >/dev/null && npm install --no-audit --no-fund playwright-core@1.56.1 >/dev/null)
fi
export DROPCAP_PLAYWRIGHT="$CACHE/node_modules/playwright-core"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
dotnet test Dropcap.Core.Tests/Dropcap.Core.Tests.csproj --filter "FullyQualifiedName~ReaderCut" "$@"
