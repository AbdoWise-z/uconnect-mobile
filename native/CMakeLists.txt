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
# Pinned to the same uconnect revision the desktop app ships with (plus its
# license commit); bump deliberately, with a round of E2E tests.
set(UCONNECT_BUILD_TESTS OFF CACHE BOOL "" FORCE)
option(UCMOBILE_BUILD_SERVER "Also build uconnect-rendezvous (for host-side tests)" OFF)
set(UCONNECT_BUILD_SERVER ${UCMOBILE_BUILD_SERVER} CACHE BOOL "" FORCE)
FetchContent_Declare(
    uconnect
    GIT_REPOSITORY https://github.com/AbdoWise-z/uconnect.git
    GIT_TAG 04319a67b78a628882fa422dc4818ae042d73fef
)
FetchContent_MakeAvailable(uconnect)

# uconnect's targets use ${CMAKE_SOURCE_DIR}/include, which only points at its
# own headers when it is the top-level project. Here it resolves to this
# directory, so mirror the public headers (same as uconnect-desktop does).
file(COPY ${uconnect_SOURCE_DIR}/include/ DESTINATION ${CMAKE_SOURCE_DIR}/include)

# 16 KiB page alignment is required for arm64 .so files on Android 15+.
if (ANDROID)
    target_link_options(uconnect_c PRIVATE "-Wl,-z,max-page-size=16384")
endif ()
