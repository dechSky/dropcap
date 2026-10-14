# 배포 압축본 만들기(Q-04): 자체 포함(.NET·Windows App SDK 포함) Dropcap.exe 와 자원을 dist\Dropcap-<rid>.zip 으로.
# 사용: powershell -File scripts\package.ps1 [-Rid win-x64|win-arm64]
param([string]$Rid = "win-x64")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "dist\Dropcap-$Rid"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
dotnet test (Join-Path $root "Dropcap.slnx") -c Release
if ($LASTEXITCODE -ne 0) { throw "시험 실패" }
dotnet publish (Join-Path $root "Dropcap.App\Dropcap.App.csproj") -c Release -r $Rid -o $out
if ($LASTEXITCODE -ne 0) { throw "빌드 실패" }
# 고지(저장소의 외부 코드 고지 + 라이선스)
Copy-Item (Join-Path $root "..\THIRD_PARTY_NOTICES.md") $out
Copy-Item (Join-Path $root "..\LICENSE") (Join-Path $out "LICENSE.txt")
$zip = Join-Path $root "dist\Dropcap-$Rid.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip
Write-Host "만듦: $zip"
