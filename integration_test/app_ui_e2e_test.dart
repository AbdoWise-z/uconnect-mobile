// On-device E2E through the app's own screens: starts the real app with empty
// state, joins a topic from the connect page, finds the host peer
// (tool/e2e_host.dart) in the device list, then browses its share and
// downloads a file, and watches its screen. storage_e2e_test.dart and
// decoder_e2e_test.dart cover the pieces underneath; this covers what a
// person taps. Driven by scripts/e2e-ios.sh, which passes:
//
//   E2E_SERVER      host:port of the rendezvous server (as seen from the device)
//   E2E_TOPIC       the uconn:// invite link the host peer joined
//   E2E_H264_SIZE   the picture size of the screen the host shares, WIDTHxHEIGHT;
//                   "any" for a real screen of whatever size; empty when the
//                   host shares none, and watching is skipped
//   E2E_HOST_NAME   the host's device name (default "E2E Host")
//   E2E_MIN_FPS     pictures per second the viewer must show (default 20; a
//                   real screen with nothing moving on it sends fewer)
//   E2E_WATCH_SECONDS  how long to keep watching (default 5)
//   E2E_HOLD        seconds to rest on each screen (for screenshots; default 0)
//   E2E_HOLD_SCREEN rest on this screen only (connect, devices, device, shares,
//                   folder, downloaded, watching)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/app/app_state.dart';
import 'package:uconnect_mobile/main.dart';

const server = String.fromEnvironment('E2E_SERVER');
const topic = String.fromEnvironment('E2E_TOPIC');
const screenSize = String.fromEnvironment('E2E_H264_SIZE');
const hostName = String.fromEnvironment('E2E_HOST_NAME', defaultValue: 'E2E Host');
const minFps = int.fromEnvironment('E2E_MIN_FPS', defaultValue: 20);
const watchSeconds = int.fromEnvironment('E2E_WATCH_SECONDS', defaultValue: 5);
const hold = int.fromEnvironment('E2E_HOLD');
const holdScreen = String.fromEnvironment('E2E_HOLD_SCREEN');

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

/// The screen named in the log, then a rest so it can be photographed.
Future<void> rest(WidgetTester tester, String screen) async {
  // ignore: avoid_print
  print('E2E_SCREEN $screen');
  if (holdScreen.isNotEmpty && holdScreen != screen) return;
  for (var i = 0; i < hold * 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Starts the app with fresh state, joins the topic from the connect page and
/// opens the host's device page.
Future<AppState> openHost(WidgetTester tester) async {
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final support = await getApplicationSupportDirectory();
  final documents = await getApplicationDocumentsDirectory();
  final data = Directory('${support.path}/ui-e2e-$stamp');
  final files = Directory('${documents.path}/ui-e2e-$stamp');
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

  // The connect page.
  final serverField = find.widgetWithText(TextField, 'Rendezvous server');
  final linkField = find.widgetWithText(TextField, 'Invite link');
  await pumpUntil(tester, () => shown(serverField), reason: 'the connect page');
  await rest(tester, 'connect');
  await tester.enterText(serverField, server);
  await tester.enterText(linkField, topic);
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Connect'));

  // The workspace, with the host in its device list.
  final host = find.text(hostName);
  await pumpUntil(tester, () => shown(host),
      timeout: const Duration(minutes: 2), reason: 'the host in the list');
  expect(state.startError, isEmpty);
  expect(state.connected, isTrue);
  await rest(tester, 'devices');
  await tester.tap(host);
  await pumpUntil(
      tester,
      () => shown(find.text('Browse files')) || shown(find.text('Watch screen')),
      reason: 'the device page');
  return state;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (server.isEmpty || topic.isEmpty) {
    test('app UI E2E (skipped: run through scripts/e2e-ios.sh)', () {},
        skip: 'E2E_SERVER / E2E_TOPIC not set');
    return;
  }

  testWidgets('join a topic, find the host, browse and download',
      (tester) async {
    final state = await openHost(tester);
    final documents = await getApplicationDocumentsDirectory();

    // Files can be browsed once the host's grants arrive.
    final granted = find.text('Open, download and upload shared folders');
    await pumpUntil(tester, () => shown(granted),
        timeout: const Duration(minutes: 2),
        reason: 'the host connected and granting storage');
    await rest(tester, 'device');
    await tester.tap(find.text('Browse files'));

    // Its share, then the file in it.
    final docs = find.text('Docs');
    await pumpUntil(tester, () => shown(docs), reason: 'the share listed');
    await rest(tester, 'shares');
    await tester.tap(docs);
    final hello = find.text('hello.txt');
    await pumpUntil(tester, () => shown(hello), reason: 'the file listed');
    await rest(tester, 'folder');

    // Download it from the row's menu.
    await tester.tap(find.descendant(
        of: find.ancestor(of: hello, matching: find.byType(ListTile)),
        matching: find.byType(PopupMenuButton<String>)));
    final download = find.text('Download');
    await pumpUntil(tester, () => shown(download), reason: 'the row menu');
    await tester.tap(download);
    final local = File('${state.downloadsDir}/hello.txt');
    await pumpUntil(tester, () => local.existsSync(),
        reason: 'the download in ${state.downloadsDir}');
    await pumpUntil(
        tester, () => local.readAsStringSync() == 'hello from the desk',
        reason: 'the downloaded contents');
    expect(local.path, startsWith(documents.path),
        reason: 'downloads belong where the Files app shows them');
    await rest(tester, 'downloaded');
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('watch the host\'s screen', (tester) async {
    await openHost(tester);

    final granted = find.text('See a live view of its screen');
    await pumpUntil(tester, () => shown(granted),
        timeout: const Duration(minutes: 2),
        reason: 'the host connected and granting its screen');
    await tester.tap(find.text('Watch screen'));

    // The picture: a texture, then the live line under it saying what is
    // being shown: "640×360 · 30 fps · 0.4 Mbit/s · ...".
    await pumpUntil(tester, () => shown(find.byType(Texture)),
        timeout: const Duration(minutes: 1), reason: 'the video texture');
    final live = RegExp(r'^(\d+)×(\d+) · (\d+) fps');
    String liveLine() {
      for (final e in find.byType(Text).evaluate()) {
        final text = (e.widget as Text).data ?? '';
        if (live.hasMatch(text)) return text;
      }
      return '';
    }

    int shownFps() {
      final m = live.firstMatch(liveLine());
      return m == null ? -1 : int.parse(m.group(3)!);
    }

    await pumpUntil(tester, () => shownFps() >= minFps,
        timeout: const Duration(minutes: 1),
        reason: 'pictures shown at $minFps fps or more');
    // It keeps going: still at pace some seconds later.
    final lines = <String>[];
    for (var second = 0; second < watchSeconds; second++) {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      lines.add(liveLine());
    }
    final m = live.firstMatch(liveLine())!;
    final size = '${m.group(1)}x${m.group(2)}';
    // ignore: avoid_print
    print('E2E_WATCH size=$size shownFps=${shownFps()} lines=$lines');
    if (screenSize != 'any') expect(size, screenSize);
    expect(shownFps(), greaterThanOrEqualTo(minFps));
    await rest(tester, 'watching');
  },
      skip: screenSize.isEmpty,
      timeout: const Timeout(Duration(minutes: 8)));
}
