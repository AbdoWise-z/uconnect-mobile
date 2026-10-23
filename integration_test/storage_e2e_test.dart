// On-device E2E: the app's own core stack, running on the phone against a
// host peer (bin/host_peer.dart) through a rendezvous server, all reached over
// `adb reverse` -- so the phone talks to 127.0.0.1 and everything stays on the
// USB cable. Driven by scripts/e2e-android.ps1, which passes the server and
// topic in --dart-define:
//
//   E2E_SERVER   host:port of the rendezvous server (as seen from the phone)
//   E2E_TOPIC    the uconn:// invite link the host peer joined
//
// The relay is forced: adb reverse carries TCP only, and deterministic E2E
// beats clever NAT punching in a test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/core/session.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';
import 'package:uconnect_mobile/core/storage/storage_offerer.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/core/wire.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

const server = String.fromEnvironment('E2E_SERVER');
const topic = String.fromEnvironment('E2E_TOPIC');

Future<void> waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 60), String? reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (server.isEmpty || topic.isEmpty) {
    test('on-device E2E (skipped: run through scripts/e2e-android.ps1)', () {},
        skip: 'E2E_SERVER / E2E_TOPIC not set');
    return;
  }

  late Session session;
  late StorageClient client;
  late Directory dataDir;

  setUpAll(() async {
    dataDir = await getApplicationSupportDirectory();
    final identity =
        await Identity.loadOrCreate('${dataDir.path}/e2e-identity');
    session = Session()..identity = identity;
    client = StorageClient(session);
    StorageOfferer(session)
      ..offered = true
      ..shares = [
        SharedFolder('Phone', (await Directory('${dataDir.path}/e2e-share')
                .create(recursive: true))
            .path)
      ];
    session.setLocalHello(
        Hello(name: 'E2E Phone', os: 'android', services: const ['storage']));
    session.setAccessPolicy(AccessPolicy(defaults: {
      Perm.storageObserve,
      Perm.storageRead,
      Perm.storageUpload,
    }));
    await session.start(SessionOptions(
      server: server,
      creds: TopicCreds.parse(topic)!,
      relayMode: 1, // RelayMode.always
    ));
  });

  tearDownAll(() async {
    await session.dispose();
  });

  String? hostDev() {
    for (final p in session.peers.values) {
      if (p.stateCode == 3 && p.hasHello && p.name == 'E2E Host') {
        return p.devId;
      }
    }
    return null;
  }

  testWidgets('the phone meets the host and verifies its identity',
      (tester) async {
    await waitFor(() => hostDev() != null, reason: 'host peer connected');
    await waitFor(() => session.peers[hostDev()]!.identityState == 'verified',
        reason: 'host identity verified');
    await waitFor(
        () => session.peers[hostDev()]!.grantedToMe
            .contains(Perm.storageRead),
        reason: 'grants from host');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the phone lists and downloads from the host', (tester) async {
    final dev = hostDev()!;
    final root = await client.list(dev, '/');
    expect(root.entries.map((e) => e.name), contains('Docs'));
    final docs = await client.list(dev, '/Docs');
    expect(docs.entries.map((e) => e.name), contains('hello.txt'));

    final local = '${dataDir.path}/e2e-downloaded.txt';
    final t = client.download(dev, '/Docs/hello.txt', local);
    await waitFor(
        () =>
            t.state == TransferState.done || t.state == TransferState.failed,
        reason: 'download settles');
    expect(t.state, TransferState.done, reason: t.error);
    expect(await File(local).readAsString(), 'hello from the desk');
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('the phone uploads to the host', (tester) async {
    final dev = hostDev()!;
    final src = File('${dataDir.path}/e2e-upload.bin');
    await src.writeAsBytes(List<int>.generate(512 * 1024, (i) => (i * 7) & 0xFF));
    final t = client.upload(dev, src.path, '/Docs');
    await waitFor(
        () =>
            t.state == TransferState.done || t.state == TransferState.failed,
        reason: 'upload settles');
    expect(t.state, TransferState.done, reason: t.error);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('file operations round-trip from the phone', (tester) async {
    final dev = hostDev()!;
    final made = await client.mkdir(dev, '/Docs', 'From Phone');
    expect(made['path'], '/Docs/From Phone');
    final renamed = await client.rename(dev, '/Docs/From Phone', 'Renamed');
    expect(renamed['path'], '/Docs/Renamed');
    await client.delete(dev, '/Docs/Renamed');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
