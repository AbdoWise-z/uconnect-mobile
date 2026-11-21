cmake_minimum_required(VERSION 3.22)
project(uconnect_mobile_native LANGUAGES C CXX)

# Builds the uconnect C ABI (uconnect_c) for the Flutter app to bind over FFI.
# Android: driven per-ABI by Gradle's externalNativeBuild; the resulting
# libuconnect_c.so is packaged into the APK automatically.
# Host (tests): scripts/build-host.ps1 configures this same file with the
# system toolchain so `flutter test` can load uconnect_c.dll on Windows.

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
# Pinned to one uconnect revision: the one the desktop app ships with, plus
# what the phones need of the library (it compiles for iOS, builds its own iOS
# framework, and reaches IPv4 hosts from an IPv6-only mobile network). Bump
# deliberately, with a round of E2E tests.
set(UCONNECT_BUILD_TESTS OFF CACHE BOOL "" FORCE)
# The library's command-line programs are of no use to the app or its tests.
set(UCONNECT_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(UCONNECT_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
option(UCMOBILE_BUILD_SERVER "Also build uconnect-rendezvous (for host-side tests)" OFF)
set(UCONNECT_BUILD_SERVER ${UCMOBILE_BUILD_SERVER} CACHE BOOL "" FORCE)
FetchContent_Declare(
    uconnect
    GIT_REPOSITORY https://github.com/AbdoWise-z/uconnect.git
    GIT_TAG 412afc92ca4773793aeb805bb821b58104239171
)
FetchContent_MakeAvailable(uconnect)

# 16 KiB page alignment is required for arm64 .so files on Android 15+.
if (ANDROID)
    target_link_options(uconnect_c PRIVATE "-Wl,-z,max-page-size=16384")
endif ()

# iOS takes an app's own dynamic code only as a framework, never a bare dylib.
# The library builds uconnect_c as uconnect_c.framework there by itself;
# scripts/build-ios.sh folds the device and simulator builds into one
# XCFramework, which the Runner target embeds and Dart opens by name
# (lib/uconnect/bindings.dart).
