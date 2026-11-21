#!/bin/sh
# End-to-end on an iOS simulator, the counterpart of e2e-android.ps1:
#   1. builds the host pieces for this Mac (libuconnect_c.dylib,
#      uconnect-rendezvous) and the iOS framework, if they are missing
#   2. encodes a short H.264 test stream (scripts/h264-sample.swift)
#   3. starts a rendezvous server and a host peer (tool/e2e_host.dart) that
#      serves a share and "shares a screen" by playing that stream
#   4. runs the integration tests on the simulator:
#        storage_e2e_test   the core stack against the host, both ways
#        sync_e2e_test      folder sync with the host, both ways
#        platform_e2e_test  power, free space and notification channels
#        decoder_e2e_test   the native video decoder, fed the stream directly
#        camera_host_e2e_test  this device's camera, watched by the host
#        display_e2e_test   this device as the host's extended display
#        app_ui_e2e_test    the app's screens: join, browse, download, watch
#                           the host's screen and its camera
#
#   sh scripts/e2e-ios.sh [simulator name or UDID]
#   E2E_HOLD=4 sh scripts/e2e-ios.sh     # rest on each screen, to watch
#   E2E_HOLD=30 E2E_HOLD_SCREEN=watching sh scripts/e2e-ios.sh   # on one only
#   E2E_TESTS=app_ui_e2e_test E2E_FLUTTER_ARGS="--plain-name camera" #     E2E_WATCH_SECONDS=60 sh scripts/e2e-ios.sh   # some of it, watching longer
#
# The simulator shares the Mac's loopback interface, so it reaches the server
# at 127.0.0.1 with no port forwarding. Needs a booted simulator (or the name
# of one to boot), Xcode, Flutter, CMake, Ninja and python3.
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

port=$((20000 + $$ % 10000))
web=$((port + 1))
size=640x360
work="$(mktemp -d "${TMPDIR:-/tmp}/uc-e2e-XXXXXX")"
share="$work/share"
mkdir -p "$share" "$work/web"
printf 'hello from the desk' > "$share/hello.txt"
swift "$root/scripts/h264-sample.swift" "$work/web/sample.h264" 640 360 90 30

cd "$root"
export UCONNECT_C_LIBRARY="$lib"
# A fresh keyed topic for this run.
topic="$(dart run bin/make_topic.dart | tail -1 | tr -d '\r')"
case "$topic" in
  uconn://*) ;;
  *) echo "could not make a topic: $topic" >&2; exit 1 ;;
esac

server=""; peer=""; http=""
cleanup() {
  code=$?
  # Whatever is already gone must not turn a passing run into a failure.
  set +e
  trap - EXIT INT TERM
  touch "$work/stop"   # the host peer leaves the topic and exits on its own
  if [ -n "$peer" ]; then sleep 2; kill "$peer" 2>/dev/null; fi
  if [ -n "$http" ]; then kill "$http" 2>/dev/null; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null; fi
  rm -rf "$work"
  exit "$code"
}
trap cleanup EXIT INT TERM

"$rvz" --port "$port" --quiet > "$work/server.log" 2>&1 &
server=$!
(cd "$work/web" && exec python3 -m http.server "$web" --bind 127.0.0.1) > "$work/http.log" 2>&1 &
http=$!
flutter test tool/e2e_host.dart \
  --dart-define="E2E_SERVER=127.0.0.1:$port" --dart-define="E2E_TOPIC=$topic" \
  --dart-define="E2E_SHARE=$share" --dart-define="E2E_H264_FILE=$work/web/sample.h264" \
  --dart-define="E2E_SYNC=$work/synced" --dart-define=E2E_WATCH_CAMERAS=true \
  --dart-define=E2E_OFFER_DISPLAY=true \
  --dart-define="E2E_H264_SIZE=$size" \
  --dart-define="E2E_READY_FILE=$work/ready" --dart-define="E2E_STOP_FILE=$work/stop" \
  > "$work/peer.log" 2>&1 &
peer=$!
# The host writes the ready file once it has published to the topic.
i=0
until [ -f "$work/ready" ]; do
  i=$((i + 1))
  if [ "$i" -gt 120 ] || ! kill -0 "$peer" 2>/dev/null; then
    echo "the host peer did not come up:" >&2; tail -40 "$work/peer.log" >&2; exit 1
  fi
  sleep 1
done

status=0
for t in ${E2E_TESTS:-storage_e2e_test sync_e2e_test platform_e2e_test decoder_e2e_test camera_host_e2e_test display_e2e_test app_ui_e2e_test}; do
  # shellcheck disable=SC2086  # E2E_FLUTTER_ARGS is a list of arguments
  flutter test "integration_test/$t.dart" -d "$udid" ${E2E_FLUTTER_ARGS:-} \
    --dart-define="E2E_SERVER=127.0.0.1:$port" \
    --dart-define="E2E_TOPIC=$topic" \
    --dart-define="E2E_H264=http://127.0.0.1:$web/sample.h264" \
    --dart-define="E2E_H264_SIZE=$size" \
    --dart-define=E2E_HOST_READS=true --dart-define=E2E_HOST_CAMERA=true \
    --dart-define="E2E_WATCH_SECONDS=${E2E_WATCH_SECONDS:-5}"     --dart-define="E2E_HOLD=${E2E_HOLD:-0}" \
    --dart-define="E2E_HOLD_SCREEN=${E2E_HOLD_SCREEN:-}" || status=$?
done
if [ "$status" -ne 0 ]; then
  echo "--- host peer log" >&2; tail -40 "$work/peer.log" >&2
fi
exit "$status"
