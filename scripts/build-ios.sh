#!/bin/sh
# Builds uconnect_c for iOS device + simulator and folds the results into an
# XCFramework for the Runner target. Untested until a Mac joins the project:
# uconnect_c is declared SHARED, so this yields dylibs to embed and sign; if
# App Store rules push toward static linking instead, build the static
# uconnect libraries and bind with DynamicLibrary.process(). Run on a Mac
# with Xcode and CMake 3.28+:
#
#   sh scripts/build-ios.sh
#
# Then add native/build-ios/uconnect_c.xcframework to the Runner target
# (Frameworks, Libraries & Embedded Content -> Do Not Embed) once; the
# repository keeps the framework out of git.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/native/build-ios"

build() { # <platform-dir> <cmake system name> <sysroot> <archs>
  cmake -S "$root/native" -B "$out/$1" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$3" \
    -DCMAKE_OSX_ARCHITECTURES="$4" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF
  cmake --build "$out/$1" --target uconnect_c
}

build device iphoneos iphoneos arm64
build simulator iphonesimulator iphonesimulator "arm64;x86_64"

rm -rf "$out/uconnect_c.xcframework"
xcodebuild -create-xcframework \
  -library "$out/device/_deps/uconnect-build/src/capi/libuconnect_c.dylib" \
  -library "$out/simulator/_deps/uconnect-build/src/capi/libuconnect_c.dylib" \
  -output "$out/uconnect_c.xcframework"
echo "made $out/uconnect_c.xcframework"
