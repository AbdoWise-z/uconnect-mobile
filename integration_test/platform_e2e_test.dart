// On-device test of the platform side of folder sync's small channels
// (SyncPlatform.kt, SyncPlatform.swift), through the Dart classes the app
// uses: the power and network conditions, the free space of a disk, and
// notifications. Needs no peer; scripts/e2e-ios.sh runs it with the rest.
//
//   E2E_HOLD   seconds to rest while the notification prompt is up


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/app/sync_platform.dart';

const hold = int.fromEnvironment('E2E_HOLD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the power and network conditions are known', (tester) async {
    var changes = 0;
    final power = PowerConditions(() => changes++);
    await power.start();
    addTearDown(power.dispose);
    expect(power.known, isTrue, reason: 'the platform answered');
    expect(changes, 1);
    // ignore: avoid_print
    print('E2E_POWER wifi=${power.wifi} charging=${power.charging}');

    // The raw answer has exactly the two flags, as booleans.
    final state = await const MethodChannel('uconnect/power')
        .invokeMapMethod<String, Object?>('state');
    expect(state!['wifi'], isA<bool>());
    expect(state['charging'], isA<bool>());
  });

  testWidgets('the free space of a disk is reported', (tester) async {
    final documents = await getApplicationDocumentsDirectory();
    final free = await freeSpaceOf(documents.path);
    expect(free, greaterThan(1024 * 1024), reason: 'bytes free under Documents');
    // A synced folder that has not been made yet is on the same disk.
    final notYet = await freeSpaceOf('${documents.path}/Sync/Not made yet/deeper');
    expect(notYet, greaterThan(1024 * 1024));
    // ignore: avoid_print
    print('E2E_FREE ${free ~/ (1024 * 1024)} MiB');
  });

  testWidgets('a notification is shown, or asked for', (tester) async {
    const channel = MethodChannel('uconnect/notify');
    String? status;
    try {
      status = await channel.invokeMethod<String>('status');
    } on MissingPluginException {
      // Android has no status(): it shows, or throws when not allowed.
    }
    // ignore: avoid_print
    print('E2E_NOTIFY status=$status');
    if (status != null) {
      expect(status, isIn(['allowed', 'quiet', 'denied', 'unasked']));
    }
    // The first show asks the user, and a test cannot answer the system's
    // prompt: give it a few seconds, then say which of the three happened.
    var outcome = 'still asking';
    final show = channel.invokeMethod<void>('show', {
      'id': 4242,
      'title': 'uConnect test',
      'text': 'A notification from the platform test.',
    }).then((_) => outcome = 'shown', onError: (Object e) {
      outcome = e is PlatformException ? 'refused (${e.code})' : 'failed ($e)';
    });
    await Future.any([show, tester.pump(const Duration(seconds: 4))]);
    for (var i = 0; i < hold * 5 && outcome == 'still asking'; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print('E2E_NOTIFY outcome=$outcome');
    if (status == 'allowed') expect(outcome, 'shown');
    if (status == 'denied') expect(outcome, startsWith('refused'));
    expect(outcome, isNot(startsWith('failed')));
    if (outcome == 'shown') {
      await channel.invokeMethod<void>('cancel', {'id': 4242});
    }
  });
}
