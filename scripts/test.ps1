# Runs the full host-side test suite, FFI and loopback E2E included, against
# the libraries from scripts/build-host.ps1 (or the paths already in the
# environment).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "native\build-host"

if (-not $env:UCONNECT_C_LIBRARY) {
  $dll = Join-Path $build "_deps\uconnect-build\src\capi\uconnect_c.dll"
  if (Test-Path $dll) { $env:UCONNECT_C_LIBRARY = $dll }
}
if (-not $env:UCONNECT_RENDEZVOUS) {
  $exe = Join-Path $build "_deps\uconnect-build\server\uconnect-rendezvous.exe"
  if (Test-Path $exe) { $env:UCONNECT_RENDEZVOUS = $exe }
}
flutter test
exit $LASTEXITCODE
