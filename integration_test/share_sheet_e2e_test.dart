// On-device test that the share sheet opens, from the invite section of
// Settings > Topic & connection. An iPad
// shows it as a popover and refuses to without a place to point at ("the
// sharePositionOrigin argument must be set"), which is what this guards: run
// it on an iPad simulator. A phone ignores the anchor.
//
// A test cannot tap inside the sheet, which another process draws, so the
// test ends with it open. iOS only: on Android the system's chooser would be
// left covering the app.
//
//   E2E_TOPIC   an invite link to show (scripts/e2e-ios.sh passes its topic)
//   E2E_HOLD    seconds to rest with the sheet open (for a screenshot)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/app/app_state.dart';
import 'package:uconnect_mobile/ui/settings_page.dart';
import 'package:uconnect_mobile/ui/share_origin.dart';

const topic = String.fromEnvironment('E2E_TOPIC');
const hold = int.fromEnvironment('E2E_HOLD');

Future<void> pumpUntil(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 30), required String reason}) async {
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

  if (!Platform.isIOS || topic.isEmpty) {
    test('share sheet (skipped: iOS, through scripts/e2e-ios.sh)', () {},
        skip: 'not iOS, or E2E_TOPIC not set');
    return;
  }

  testWidgets('the invite link\'s share sheet opens', (tester) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final data = Directory('${support.path}/share-e2e-$stamp');
    final files = Directory('${documents.path}/share-e2e-$stamp');
    await data.create(recursive: true);
    await files.create(recursive: true);
    final state = AppState(data.path, filesDir: files.path);
    addTearDown(() async {
      state.shutdown();
      await data.delete(recursive: true);
      await files.delete(recursive: true);
    });
    await state.init();
    expect(state.initError, isEmpty);
    // A topic to invite to; the device is not connected, which sharing a
    // link does not need.
    state.store.topicUri = topic;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsPage(state: state))));

    final row = find.text('Topic & connection');
    await pumpUntil(tester, () => shown(row), reason: 'the settings page');
    await tester.ensureVisible(row.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(row.first);
    final share = find.widgetWithText(FilledButton, 'Share');
    await pumpUntil(tester, () => shown(share), reason: 'the invite section');
    await tester.ensureVisible(share);
    await tester.pump(const Duration(milliseconds: 300));

    // The place the sheet will point at: the button, somewhere on screen.
    final origin = shareOrigin(tester.element(find.text('Share')));
    expect(origin, isNotNull);
    expect(origin!.isEmpty, isFalse);
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(Offset.zero & view, predicate<Rect>((screen) => screen.overlaps(origin)));

    // A refusal comes back as an error from the plugin, which fails the test.
    await tester.tap(share);
    for (var i = 0; i < (3 + hold) * 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.takeException(), isNull);
    // ignore: avoid_print
    print('E2E_SHARE opened origin=$origin screen=$view');
  });
}
