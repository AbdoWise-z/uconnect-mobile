// End-to-end on the host: a local rendezvous server, two Sessions in this
// process (one offering storage, one asking), the full hello / id /
// perm.granted exchange, then listing, download, upload and the change
// operations over the real uconnect library.
//
// Needs the native pieces, pointed at by environment variables:
//   UCONNECT_C_LIBRARY    the uconnect_c shared library built for this host
//   UCONNECT_RENDEZVOUS   the uconnect-rendezvous executable
// Without them the suite skips rather than fails.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/core/session.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';
import 'package:uconnect_mobile/core/storage/storage_offerer.dart';
import 'package:uconnect_mobile/core/wire.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

Future<void> waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 45), String? reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  final lib = Platform.environment['UCONNECT_C_LIBRARY'];
  final serverExe = Platform.environment['UCONNECT_RENDEZVOUS'];
  if (lib == null || serverExe == null) {
    test('loopback E2E (skipped: set UCONNECT_C_LIBRARY and UCONNECT_RENDEZVOUS)',
        () {}, skip: 'native pieces not configured');
    return;
  }

  late Process server;
  late int port;
  late Directory tempDir;
  late Session a, b;
  late StorageOfferer offererA;
  late StorageClient clientB;
  late Directory shareA;

  setUpAll(() async {
    port = 20000 + Random().nextInt(20000);
    server = await Process.start(serverExe, ['--port', '$port', '--quiet']);
    tempDir = await Directory.systemTemp.createTemp('ucmob');
    shareA = await Directory('${tempDir.path}/a-docs').create();
    await File('${shareA.path}/readme.txt').writeAsString('hello from A');

    final idA = await Identity.loadOrCreate('${tempDir.path}/idA');
    final idB = await Identity.loadOrCreate('${tempDir.path}/idB');

    a = Session()..identity = idA;
    b = Session()..identity = idB;
    offererA = StorageOfferer(a)
      ..offered = true
      ..shares = [SharedFolder('Docs', shareA.path)];
    StorageOfferer(b); // B serves nothing but still answers politely
    StorageClient(a);
    clientB = StorageClient(b);

    a.setLocalHello(
        Hello(name: 'Host A', os: 'windows', services: const ['storage']));
    b.setLocalHello(Hello(name: 'Phone B', os: 'android', services: const []));
    a.setAccessPolicy(AccessPolicy(defaults: {
      Perm.storageObserve,
      Perm.storageRead,
      Perm.storageUpload,
      Perm.storageWrite,
    }));
    b.setAccessPolicy(AccessPolicy());

    final creds = TopicCreds.generate();
    await a.start(SessionOptions(
        server: '127.0.0.1:$port', creds: creds, forceRelay: true));
    await b.start(SessionOptions(
        server: '127.0.0.1:$port', creds: creds, forceRelay: true));
  });

  tearDownAll(() async {
    await a.dispose();
    await b.dispose();
    offererA.dispose();
    server.kill();
    await server.exitCode;
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // files may still be settling on Windows; leave the temp dir behind
    }
  });

  String? devA() {
    for (final p in b.peers.values) {
      if (p.stateCode == 3) return p.devId;
    }
    return null;
  }

  test('the devices meet, prove identities and exchange grants', () async {
    await waitFor(() => devA() != null, reason: 'B connected to A');
    await waitFor(() {
      final p = b.peers[devA()]!;
      return p.hasHello && p.identityState == 'verified';
    }, reason: 'A\'s hello and identity at B');
    final p = b.peers[devA()]!;
    expect(p.name, 'Host A');
    expect(p.services, contains('storage'));
    expect(p.fingerprint, a.identity!.fingerprint);
    await waitFor(() => b.peers[devA()]!.grantedToMe.contains(Perm.storageRead),
        reason: 'grants from A');
    expect(
        b.peers[devA()]!.grantedToMe,
        containsAll(
            [Perm.storageObserve, Perm.storageRead, Perm.storageUpload]));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('B lists A\'s shares and the files inside', () async {
    final root = await clientB.list(devA()!, '/');
    expect(root.entries.map((e) => e.name), contains('Docs'));
    final docs = await clientB.list(devA()!, '/Docs');
    expect(docs.entries.map((e) => e.name), contains('readme.txt'));
    final entry = docs.entries.firstWhere((e) => e.name == 'readme.txt');
    expect(entry.dir, isFalse);
    expect(entry.size, 12);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('B downloads a file and the bytes verify', () async {
    final local = '${tempDir.path}/got-readme.txt';
    final t = clientB.download(devA()!, '/Docs/readme.txt', local);
    await waitFor(
        () =>
            t.state == TransferState.done || t.state == TransferState.failed,
        reason: 'download finished');
    expect(t.state, TransferState.done, reason: t.error);
    expect(await File(local).readAsString(), 'hello from A');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('B uploads a file and A saves exactly those bytes', () async {
    final src = File('${tempDir.path}/upload.bin');
    final bytes = List<int>.generate(300 * 1024, (i) => (i * 31) & 0xFF);
    await src.writeAsBytes(bytes);
    final t = clientB.upload(devA()!, src.path, '/Docs');
    await waitFor(
        () =>
            t.state == TransferState.done || t.state == TransferState.failed,
        reason: 'upload finished');
    expect(t.state, TransferState.done, reason: t.error);
    final saved = File('${shareA.path}/upload.bin');
    expect(await saved.exists(), isTrue);
    expect(await saved.length(), bytes.length);
    expect((await saved.readAsBytes()).sublist(0, 64), bytes.sublist(0, 64));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('mkdir, rename and delete round-trip', () async {
    final made = await clientB.mkdir(devA()!, '/Docs', 'New Folder');
    expect(made['path'], '/Docs/New Folder');
    expect(await Directory('${shareA.path}/New Folder').exists(), isTrue);

    final renamed =
        await clientB.rename(devA()!, '/Docs/New Folder', 'Renamed');
    expect(renamed['path'], '/Docs/Renamed');
    expect(await Directory('${shareA.path}/Renamed').exists(), isTrue);

    await clientB.delete(devA()!, '/Docs/Renamed');
    expect(await Directory('${shareA.path}/Renamed').exists(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('permissions are enforced: withdrawing read blocks downloads', () async {
    a.setAccessPolicy(AccessPolicy(defaults: {Perm.storageObserve}));
    final local = '${tempDir.path}/forbidden.txt';
    final t = clientB.download(devA()!, '/Docs/readme.txt', local);
    await waitFor(
        () =>
            t.state == TransferState.done || t.state == TransferState.failed,
        reason: 'forbidden download settles');
    expect(t.state, TransferState.failed);
    expect(t.error, contains('forbidden'));
  }, timeout: const Timeout(Duration(minutes: 1)));
}
