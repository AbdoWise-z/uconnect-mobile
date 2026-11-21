// On-device E2E of sharing this device's camera: the core stack offers the
// camera (CameraCapturer.kt, CameraCapturer.swift) as the app does, the host
// (tool/e2e_host.dart, with E2E_WATCH_CAMERAS) watches it for a few seconds
// and writes what arrived to camera-seen.txt in its share, and this test
// reads that back. Driven by scripts/e2e-ios.sh, where the "camera" is the
// simulator's simulated one:
//
//   E2E_SERVER   host:port of the rendezvous server (as seen from the device)
//   E2E_TOPIC    the uconn:// invite link the host peer joined

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/core/screen/camera_capture.dart';
import 'package:uconnect_mobile/core/screen/remote_input.dart';
import 'package:uconnect_mobile/core/screen/screen_host.dart';
import 'package:uconnect_mobile/core/session.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';
import 'package:uconnect_mobile/core/wire.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

const server = String.fromEnvironment('E2E_SERVER');
const topic = String.fromEnvironment('E2E_TOPIC');

Future<void> waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 60), required String reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (server.isEmpty || topic.isEmpty) {
    test('camera host E2E (skipped: run through scripts/e2e-ios.sh)', () {},
        skip: 'E2E_SERVER / E2E_TOPIC not set');
    return;
  }

  testWidgets('the host watches this device\'s camera', (tester) async {
    final camera = CameraCaptureController();
    expect(camera.supported, isTrue);
    camera.allCameras = await camera.cameras();
    // ignore: avoid_print
    print('E2E_CAMERA cameras=${[for (final c in camera.allCameras) '${c.id}:${c.facing}']}');
    expect(camera.allCameras, isNotEmpty, reason: 'a camera to offer');

    final dataDir = await getApplicationSupportDirectory();
    final identity =
        await Identity.loadOrCreate('${dataDir.path}/e2e-camera-identity');
    final session = Session()..identity = identity;
    addTearDown(session.dispose);
    final client = StorageClient(session);
    // The camera host, set up as AppState.cameraHost is.
    ScreenHost(session, camera, RemoteInput(),
            askConsent: (dev, name, {bool control = false, bool camera = false}) async => true,
            prefix: 'cam',
            videoKind: 3,
            viewPerm: Perm.cameraView,
            directPerm: Perm.cameraDirect)
        .offered = true;
    session.setLocalHello(Hello(
        name: 'E2E Camera', os: Platform.operatingSystem, services: const [Services.camera]));
    session.setAccessPolicy(
        AccessPolicy(defaults: {Perm.cameraView, Perm.cameraDirect}));
    await session.start(SessionOptions(
      server: server,
      creds: TopicCreds.parse(topic)!,
      relayMode: 1, // RelayMode.always
    ));

    String? hostDev() {
      for (final p in session.peers.values) {
        if (p.stateCode == 3 && p.hasHello && p.name == 'E2E Host') return p.devId;
      }
      return null;
    }

    await waitFor(() => hostDev() != null, reason: 'the host connected');
    await waitFor(
        () => session.peers[hostDev()]!.grantedToMe.contains(Perm.storageRead),
        reason: 'grants from the host');

    // The host notices the camera, watches for six seconds, and reports.
    final local = File('${dataDir.path}/e2e-camera-seen.txt');
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var report = '';
    while (!report.contains('units=')) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the host did not report on the camera; last read: "$report"');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final docs = await client.list(hostDev()!, '/Docs');
      if (!docs.entries.any((e) => e.name == 'camera-seen.txt')) continue;
      if (local.existsSync()) local.deleteSync();
      final t = client.download(hostDev()!, '/Docs/camera-seen.txt', local.path);
      await waitFor(
          () =>
              t.state == TransferState.done || t.state == TransferState.failed,
          reason: 'download settles');
      if (t.state == TransferState.done) report = await local.readAsString();
    }
    // ignore: avoid_print
    print('E2E_CAMERA host saw: $report');
    final fields = {
      for (final part in report.split(' '))
        if (part.contains('=')) part.split('=')[0]: part.substring(part.indexOf('=') + 1)
    };
    expect(fields['state'], 'active', reason: report);
    expect(fields['firstIsKeyframe'], 'true', reason: report);
    expect(fields['firstHasParameterSets'], 'true', reason: report);
    // Six seconds at 30 a second, with room for a slow start.
    expect(int.parse(fields['units']!), greaterThan(100), reason: report);
    final size = fields['size']!.split('x').map(int.parse).toList();
    expect(size[0], greaterThan(0));
    expect(size[1], greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
