#!/bin/sh
# Builds uconnect_c for iOS devices and the simulator and folds the two into
# native/build-ios/uconnect_c.xcframework, which the Runner target links,
# embeds and signs. Run it on a Mac with Xcode, CMake 3.28+ and Ninja before
# the first `flutter build ios` / `flutter run`, and again whenever the
# uconnect revision pinned in native/CMakeLists.txt changes:
#
#   sh scripts/build-ios.sh
#
# uconnect_c is a dynamic framework (see native/CMakeLists.txt): Dart opens
# uconnect_c.framework/uconnect_c by name. The repository keeps the built
# framework out of git, so a fresh checkout fails in Xcode with "there is no
# XCFramework found at ..." until this has run.
#
# 15.0 is the Runner target's deployment target, and the lowest Xcode 27's C++
# standard library still supports.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/native/build-ios"
target="${IOS_DEPLOYMENT_TARGET:-15.0}"

build() { # <dir> <sysroot> <archs>
  cmake -S "$root/native" -B "$out/$1" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$2" \
    -DCMAKE_OSX_ARCHITECTURES="$3" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$target" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$out/$1" --target uconnect_c
}

build device iphoneos arm64
build simulator iphonesimulator "arm64;x86_64"

framework="_deps/uconnect-build/src/capi/uconnect_c.framework"
rm -rf "$out/uconnect_c.xcframework"
xcodebuild -create-xcframework \
  -framework "$out/device/$framework" \
  -framework "$out/simulator/$framework" \
  -output "$out/uconnect_c.xcframework"
echo "made $out/uconnect_c.xcframework"
