// On-device E2E of folder sync, through the app's own state (AppState, as the
// pages use it) rather than its screens: the host (tool/e2e_host.dart) offers
// a folder, the device joins it, the host's file arrives on the device, and a
// file made on the device arrives on the host. Driven by scripts/e2e-ios.sh:
//
//   E2E_SERVER   host:port of the rendezvous server (as seen from the device)
//   E2E_TOPIC    the uconn:// invite link the host peer joined

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/app/app_state.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';

const server = String.fromEnvironment('E2E_SERVER');
const topic = String.fromEnvironment('E2E_TOPIC');
const folderLabel = 'E2E Sync';

Future<void> waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 90), required String reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (server.isEmpty || topic.isEmpty) {
    test('sync E2E (skipped: run through scripts/e2e-ios.sh)', () {},
        skip: 'E2E_SERVER / E2E_TOPIC not set');
    return;
  }

  testWidgets('a folder the host offers syncs both ways', (tester) async {
    // Fresh state, in the places the app itself uses.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final data = Directory('${support.path}/sync-e2e-$stamp');
    final files = Directory('${documents.path}/sync-e2e-$stamp');
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

    // Folder offers are shown only from devices granted Receive sync here,
    // and a folder is sent only to those granted Offer sync.
    await state.setDefaultPermissions({
      ...state.store.defaultPermissions,
      Perm.syncOffer,
      Perm.syncReceive,
    });
    await state.saveSettings(server: server, topicUri: topic);
    await state.connect();
    expect(state.startError, isEmpty);

    // The host's offer.
    String? hostKey;
    String? folderId;
    await waitFor(() {
      for (final offer in state.syncOffers.entries) {
        for (final folder in offer.value) {
          if (folder['label'] == folderLabel) {
            hostKey = offer.key;
            folderId = folder['id'];
            return true;
          }
        }
      }
      return false;
    }, reason: 'the host offering "$folderLabel"');

    // Joined into Documents, where the Files app shows it on iOS.
    final path = '${files.path}/Sync/$folderLabel';
    expect(await state.joinSyncFolder(hostKey!, folderId!, folderLabel, path),
        isTrue);
    expect(path, startsWith(documents.path));

    // Host to device.
    final fromHost = File('$path/from-host.txt');
    await waitFor(
        () =>
            fromHost.existsSync() &&
            fromHost.readAsStringSync() == 'synced from the host',
        reason: 'from-host.txt arriving on the device');

    // Device to host: seen through the host's read-only "Synced" share.
    final words = 'synced from the device $stamp';
    await File('$path/from-device.txt').writeAsString(words);
    final hostDev = state.session.peers.values
        .firstWhere((p) => p.identityKey == hostKey)
        .devId;
    final back = File('${data.path}/from-device-back.txt');
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    var got = '';
    while (got != words) {
      if (DateTime.now().isAfter(deadline)) {
        fail('from-device.txt did not reach the host; last read: "$got"');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final listing = await state.storageClient.list(hostDev, '/Synced');
      if (!listing.entries.any((e) => e.name == 'from-device.txt')) continue;
      if (back.existsSync()) back.deleteSync();
      final t = state.storageClient
          .download(hostDev, '/Synced/from-device.txt', back.path);
      await waitFor(
          () =>
              t.state == TransferState.done || t.state == TransferState.failed,
          reason: 'download settles');
      if (t.state == TransferState.done) got = await back.readAsString();
    }
    // ignore: avoid_print
    print('E2E_SYNC both ways in ${DateTime.now().millisecondsSinceEpoch - stamp} ms');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
