# Builds uconnect_c (and the rendezvous server) for this Windows host, so the
# Dart test suite can run against the real library:
#   powershell -File scripts/build-host.ps1
#   powershell -File scripts/test.ps1
# Needs CMake, Ninja and a C++20 compiler on PATH (or set $env:CMAKE/$env:NINJA).

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "native\build-host"
$cmake = if ($env:CMAKE) { $env:CMAKE } else { "cmake" }

& $cmake -S (Join-Path $root "native") -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release -DUCMOBILE_BUILD_SERVER=ON
if ($LASTEXITCODE -ne 0) { exit 1 }
& $cmake --build $build --target uconnect_c uconnect-rendezvous
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "uconnect_c: $build\_deps\uconnect-build\src\capi\"
Write-Host "rendezvous: $build\_deps\uconnect-build\server\"
