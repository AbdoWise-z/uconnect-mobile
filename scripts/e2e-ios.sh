#!/bin/sh
# End-to-end on an iOS simulator, the counterpart of e2e-android.ps1:
#   1. builds the host pieces for this Mac (libuconnect_c.dylib,
#      uconnect-rendezvous) and the iOS framework, if they are missing
#   2. starts a rendezvous server and a host peer serving a share
#   3. runs integration_test/storage_e2e_test.dart (the core stack) and
#      integration_test/app_ui_e2e_test.dart (the app's screens) on the
#      simulator
#
#   sh scripts/e2e-ios.sh [simulator name or UDID]
#
# The simulator shares the Mac's loopback interface, so it reaches the server
# at 127.0.0.1 with no port forwarding. Needs a booted simulator (or the name
# of one to boot), Xcode, Flutter, CMake and Ninja.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
device="${1:-booted}"

host="$root/native/build-host"
lib="$host/_deps/uconnect-build/src/capi/libuconnect_c.dylib"
rvz="$host/_deps/uconnect-build/server/uconnect-rendezvous"
if [ ! -f "$lib" ] || [ ! -x "$rvz" ]; then
  cmake -S "$root/native" -B "$host" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DUCMOBILE_BUILD_SERVER=ON
  cmake --build "$host" --target uconnect_c uconnect-rendezvous
fi
[ -d "$root/native/build-ios/uconnect_c.xcframework" ] || sh "$root/scripts/build-ios.sh"

if [ "$device" = booted ]; then
  udid="$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)"
  [ -n "$udid" ] || { echo "no booted simulator; pass a name, e.g. \"iPhone 17\"" >&2; exit 1; }
else
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" >/dev/null
  udid="$device"
fi

port=$((20000 + $$ % 20000))
work="$(mktemp -d "${TMPDIR:-/tmp}/uc-e2e-XXXXXX")"
share="$work/share"
mkdir -p "$share"
printf 'hello from the desk' > "$share/hello.txt"

cd "$root"
export UCONNECT_C_LIBRARY="$lib"
# A fresh keyed topic for this run.
topic="$(dart run bin/make_topic.dart | tail -1 | tr -d '\r')"
case "$topic" in
  uconn://*) ;;
  *) echo "could not make a topic: $topic" >&2; exit 1 ;;
esac

server=""; peer=""
cleanup() {
  [ -n "$peer" ] && kill "$peer" 2>/dev/null
  [ -n "$server" ] && kill "$server" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

"$rvz" --port "$port" --quiet > "$work/server.log" 2>&1 &
server=$!
dart run bin/host_peer.dart "127.0.0.1:$port" "$topic" "$share" > "$work/peer.log" 2>&1 &
peer=$!
# The peer prints READY once it has published to the topic.
i=0
until grep -q '^READY ' "$work/peer.log" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 60 ] || ! kill -0 "$peer" 2>/dev/null; then
    echo "the host peer did not come up:" >&2; cat "$work/peer.log" >&2; exit 1
  fi
  sleep 1
done

# The core stack first, then the same journey through the app's screens.
# E2E_HOLD=<seconds> rests on each screen of the second, for screenshots.
status=0
for t in storage_e2e_test app_ui_e2e_test; do
  flutter test "integration_test/$t.dart" -d "$udid" \
    --dart-define="E2E_SERVER=127.0.0.1:$port" \
    --dart-define="E2E_TOPIC=$topic" \
    --dart-define="E2E_HOLD=${E2E_HOLD:-0}" || status=$?
done
if [ "$status" -ne 0 ]; then
  echo "--- host peer log" >&2; tail -40 "$work/peer.log" >&2
fi
exit "$status"
