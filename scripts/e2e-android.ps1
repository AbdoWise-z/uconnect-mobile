# End-to-end on a connected Android device:
#   1. builds the host pieces (uconnect_c.dll, uconnect-rendezvous.exe)
#   2. starts a rendezvous server and a host peer serving a share
#   3. `adb reverse`s the server port so the phone reaches it at 127.0.0.1
#   4. runs integration_test/storage_e2e_test.dart on the device
#
#   powershell -File scripts/e2e-android.ps1 [-DeviceId <adb serial>]
param([string]$DeviceId = "")

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "native\build-host"
$dll = Join-Path $build "_deps\uconnect-build\src\capi\uconnect_c.dll"
$rvz = Join-Path $build "_deps\uconnect-build\server\uconnect-rendezvous.exe"
if (-not (Test-Path $dll) -or -not (Test-Path $rvz)) {
  & powershell -File (Join-Path $PSScriptRoot "build-host.ps1")
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

$adbArgs = @()
if ($DeviceId) { $adbArgs = @("-s", $DeviceId) }

$port = Get-Random -Minimum 20000 -Maximum 40000
$share = Join-Path $env:TEMP "uc-e2e-share-$port"
New-Item -ItemType Directory -Force $share | Out-Null
Set-Content -Encoding utf8 -NoNewline (Join-Path $share "hello.txt") "hello from the desk"

# A fresh keyed topic for this run.
$env:UCONNECT_C_LIBRARY = $dll
$topic = (dart run (Join-Path $root "bin\make_topic.dart")).Trim()
if (-not $topic.StartsWith("uconn://")) { Write-Error "could not make a topic: $topic"; exit 1 }

$server = Start-Process $rvz -ArgumentList @("--port", "$port", "--quiet") -PassThru -NoNewWindow
$peer = Start-Process "dart" -ArgumentList @("run", (Join-Path $root "bin\host_peer.dart"), "127.0.0.1:$port", $topic, $share) -PassThru -NoNewWindow
try {
  & adb @adbArgs reverse "tcp:$port" "tcp:$port"
  if ($LASTEXITCODE -ne 0) { exit 1 }
  $flutterArgs = @("test", "integration_test/storage_e2e_test.dart",
    "--dart-define=E2E_SERVER=127.0.0.1:$port",
    "--dart-define=E2E_TOPIC=$topic")
  if ($DeviceId) { $flutterArgs += @("-d", $DeviceId) }
  Push-Location $root
  & flutter @flutterArgs
  $code = $LASTEXITCODE
  Pop-Location
  exit $code
} finally {
  & adb @adbArgs reverse --remove "tcp:$port" 2>$null
  if (-not $peer.HasExited) { Stop-Process -Id $peer.Id -Force -Confirm:$false }
  if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force -Confirm:$false }
}
