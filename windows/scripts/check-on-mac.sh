#!/bin/bash
# 맥(또는 리눅스)에서 윈도우 앱의 C# 를 컴파일까지 점검한다. 실행 파일은 만들지 않는다(윈도우 전용 도구 단계를 끔).
# 핵심·화면 공용 코드의 시험은: dotnet test windows/Dropcap.slnx
set -euo pipefail
cd "$(dirname "$0")/.."
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
dotnet build Dropcap.App/Dropcap.App.csproj -r win-x64 -p:DropcapMacCheck=true "$@"
