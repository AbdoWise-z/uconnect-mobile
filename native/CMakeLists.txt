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
# Pinned to the uconnect revision the desktop app ships with, plus the one
# commit that lets the library compile for iOS (uconnect PR #79; it changes
# nothing on other platforms). Bump deliberately, with a round of E2E tests.
set(UCONNECT_BUILD_TESTS OFF CACHE BOOL "" FORCE)
option(UCMOBILE_BUILD_SERVER "Also build uconnect-rendezvous (for host-side tests)" OFF)
set(UCONNECT_BUILD_SERVER ${UCMOBILE_BUILD_SERVER} CACHE BOOL "" FORCE)
FetchContent_Declare(
    uconnect
    GIT_REPOSITORY https://github.com/AbdoWise-z/uconnect.git
    GIT_TAG fd147a370998e7973d2720f227af4c462102ebe5
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

# iOS takes an app's own dynamic code only as a framework, never a bare dylib,
# so uconnect_c is built as uconnect_c.framework there. scripts/build-ios.sh
# folds the device and simulator builds into one XCFramework, which the Runner
# target embeds and Dart opens by name (lib/uconnect/bindings.dart).
if (IOS)
    set_target_properties(uconnect_c PROPERTIES
        FRAMEWORK TRUE
        MACOSX_FRAMEWORK_IDENTIFIER dev.uconnect.uconnect-c
        MACOSX_FRAMEWORK_SHORT_VERSION_STRING 1.0.0
        MACOSX_FRAMEWORK_BUNDLE_VERSION 1
        MACOSX_FRAMEWORK_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/ios-framework-Info.plist.in)
endif ()
