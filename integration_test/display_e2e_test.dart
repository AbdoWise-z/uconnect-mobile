// On-device E2E of being an extended display (protocol 7.6), through the app's
// own screens: the device offers itself, the host (tool/e2e_host.dart with
// E2E_OFFER_DISPLAY) asks, the consent prompt is answered, the host's
// "monitor" is shown full screen at pace, and Stop ends it. Driven by
// scripts/e2e-ios.sh:
//
//   E2E_SERVER      host:port of the rendezvous server (as seen from the device)
//   E2E_TOPIC       the uconn:// invite link the host peer joined
//   E2E_H264_SIZE   the picture size of the host's monitor, WIDTHxHEIGHT
//   E2E_HOLD        seconds to rest on the display (for screenshots; default 0)
//   E2E_WATCH_SECONDS, E2E_MIN_FPS   how long to watch, and the pace to hold

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/app/app_state.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/main.dart';
import 'package:uconnect_mobile/ui/display_view.dart';

const server = String.fromEnvironment('E2E_SERVER');
const topic = String.fromEnvironment('E2E_TOPIC');
const monitorSize = String.fromEnvironment('E2E_H264_SIZE');
const hold = int.fromEnvironment('E2E_HOLD');
// 1 sends everything through the relay, as a device reached over `adb
// reverse` must (the cable carries no UDP). A display then gives up its
// insistence on a direct path, which only this test relies on.
const relay = int.fromEnvironment('E2E_RELAY');
const watchSeconds = int.fromEnvironment('E2E_WATCH_SECONDS', defaultValue: 5);
// Pictures a second the display must still be getting at the end (a lossy
// path gets fewer than a cable's-length one).
const minFps = int.fromEnvironment('E2E_MIN_FPS', defaultValue: 20);

Future<void> pumpUntil(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 60), required String reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: $reason');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

bool shown(Finder finder) => finder.evaluate().isNotEmpty;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (server.isEmpty || topic.isEmpty) {
    test('display E2E (skipped: run through scripts/e2e-ios.sh)', () {},
        skip: 'E2E_SERVER / E2E_TOPIC not set');
    return;
  }

  testWidgets('the host uses this device as an extended display',
      (tester) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final data = Directory('${support.path}/display-e2e-$stamp');
    final files = Directory('${documents.path}/display-e2e-$stamp');
    await data.create(recursive: true);
    await files.create(recursive: true);
    final state = AppState(data.path, filesDir: files.path);
    addTearDown(() async {
      state.shutdown();
      await data.delete(recursive: true);
      await files.delete(recursive: true);
    });
    await tester.pumpWidget(UConnectApp(state));
    await state.init();
    expect(state.initError, isEmpty);

    // Offered, and allowed to hosts in general, but not without asking: the
    // prompt is part of what is tested.
    await state.setDefaultPermissions({
      ...state.store.defaultPermissions,
      Perm.displayShow,
    });
    await state.saveSettings(
        server: server, topicUri: topic, offerDisplay: true, relayMode: relay);
    await state.connect();
    expect(state.startError, isEmpty);

    // The host notices a device offering `display` and asks.
    final allow = find.widgetWithText(FilledButton, 'Allow');
    await pumpUntil(tester, () => shown(allow),
        timeout: const Duration(minutes: 2), reason: 'the consent prompt');
    expect(find.text('Use this device as a display?'), findsOneWidget);
    expect(find.textContaining('E2E Host'), findsWidgets);
    await tester.tap(allow);

    // The display page, then the host's monitor on it.
    await pumpUntil(tester, () => shown(find.byType(DisplayPage)),
        reason: 'the display page');
    await pumpUntil(tester, () => shown(find.byType(Texture)),
        timeout: const Duration(minutes: 1), reason: 'the host\'s picture');
    final viewer = state.displaySink.viewer;
    await pumpUntil(tester, () => viewer.unitsPerSecond >= minFps,
        timeout: const Duration(minutes: 1),
        reason: 'pictures arriving at $minFps a second or more');
    final rates = <int>[];
    for (var second = 0; second < watchSeconds; second++) {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      rates.add(viewer.unitsPerSecond.round());
    }
    // ignore: avoid_print
    print('E2E_DISPLAY size=${viewer.width}x${viewer.height} fps=$rates '
        'kbps=${viewer.kbps.round()} loss=${viewer.lossPct.toStringAsFixed(1)} '
        'host=${viewer.hostStats}');
    if (monitorSize.isNotEmpty) {
      expect('${viewer.width}x${viewer.height}', monitorSize);
    }
    expect(rates.last, greaterThanOrEqualTo(minFps));
    expect(state.displaySink.showing, isTrue);
    for (var i = 0; i < hold * 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // A tap brings up the bar; Stop ends the session and closes the page.
    await tester.tapAt(tester.getCenter(find.byType(DisplayPage)));
    final stop = find.widgetWithText(FilledButton, 'Stop');
    // It slides in from above the screen: wait until it is on it.
    await pumpUntil(
        tester, () => shown(stop) && tester.getTopLeft(stop).dy >= 0,
        reason: 'the bar with Stop');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Extended display for E2E Host'), findsOneWidget);
    await tester.tap(stop);
    await pumpUntil(tester, () => !shown(find.byType(DisplayPage)),
        reason: 'the display page closing');
    expect(state.displaySink.showing, isFalse);
    // The app lives on after a Stop, as it does in use: the word reaches the
    // host, which removes its monitor at once rather than on a timeout.
    await tester.pump(const Duration(seconds: 3));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
