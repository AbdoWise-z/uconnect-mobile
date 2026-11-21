// A headless uConnect peer for the on-device E2E tests that also shares a
// "screen" and a "camera": like bin/host_peer.dart it joins a topic and serves
// a storage share with everything granted, and on top of that it offers screen
// and camera sharing, playing a recorded H.264 stream
// (scripts/h264-sample.swift) in a loop as if it were the live capture. A
// device can then watch either with no real screen, camera, capture permission
// or window involved.
//
// With E2E_SYNC=<dir> (or @temp) it offers that folder for folder sync to
// every proven peer, holding from-host.txt, and serves the same folder as the
// share "Synced" so a device can see what arrived in it.
//
// With E2E_WATCH_CAMERAS=true it also watches the camera of each peer that
// offers one and lets this host view it: for a few seconds, counting the
// access units that arrive, then writes what it saw to camera-seen.txt in its
// share. It has no decoder; that the stream arrives whole and starts with a
// keyframe carrying parameter sets is what it can tell.
//
// With E2E_OFFER_DISPLAY=true it asks each peer that offers `display` to be
// its extended display (protocol 7.6: dsp.request, then on dsp.accept a screen
// session under dsp.* with video on datagram kind 4), playing the recording as
// the monitor. What the peer answered goes to display-asked.txt in the share.
//
// It also reads what a device shares: from every peer that offers a share
// named "Phone" holding from-phone.txt, it downloads that file into its own
// share as fetched-from-phone.txt, where the device's test finds it again.
//
// The screen host needs dart:ui (for Size), which the plain Dart VM lacks, so
// this runs under the Flutter test runner rather than `dart run`:
//
//   flutter test tool/e2e_host.dart \
//     --dart-define=E2E_SERVER=host:port --dart-define=E2E_TOPIC=uconn://... \
//     --dart-define=E2E_SHARE=<dir> --dart-define=E2E_H264_FILE=<file> \
//     --dart-define=E2E_H264_SIZE=640x360 \
//     --dart-define=E2E_READY_FILE=<file> --dart-define=E2E_STOP_FILE=<file>
//
// It writes the ready file once published and serves until the stop file
// appears (or E2E_SERVE_SECONDS pass). Point UCONNECT_C_LIBRARY at a host
// build of uconnect_c first. scripts/e2e-ios.sh does all of this.
//
// The same host runs on a phone through integration_test/device_host_test.dart
// (`flutter test integration_test/device_host_test.dart -d <device>
// --no-uninstall ...`), which is how a stream is sent over a real mobile
// network. There it prints "E2E_HOST READY <id>" instead of writing a file,
// and takes:
//
//   E2E_SHARE=@temp   a share made in the app's temporary folder, holding
//                     hello.txt
//   E2E_H264=<url>    the stream fetched over HTTP instead of read from a file
//   E2E_RELAY=0       let peers connect directly when they can (the default,
//                     1, forces the relay: deterministic on one machine)
//   E2E_CAPTURE=camera   share the device's camera through its real encoder
//   E2E_CAPTURE=screen   share the device's real screen with its real encoder
//                     instead of the recording (Android: the system's consent
//                     dialog comes up on the device when a viewer asks). The
//                     recording is a fixed stream, so on a thin or lossy path
//                     the sender can only drop frames; the real encoder lowers
//                     its bitrate and size as the app does.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/core/screen/camera_capture.dart';
import 'package:uconnect_mobile/core/screen/remote_input.dart';
import 'package:uconnect_mobile/core/screen/screen_capture.dart';
import 'package:uconnect_mobile/core/screen/screen_host.dart';
import 'package:uconnect_mobile/core/screen/screen_viewer.dart';
import 'package:uconnect_mobile/core/session.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';
import 'package:uconnect_mobile/core/storage/storage_offerer.dart';
import 'package:uconnect_mobile/core/sync/sync_client.dart';
import 'package:uconnect_mobile/core/sync/sync_folder.dart';
import 'package:uconnect_mobile/core/wire.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

const server = String.fromEnvironment('E2E_SERVER');
const topic = String.fromEnvironment('E2E_TOPIC');
const shareOption = String.fromEnvironment('E2E_SHARE');
const streamFile = String.fromEnvironment('E2E_H264_FILE');
const streamUrl = String.fromEnvironment('E2E_H264');
const relayMode = int.fromEnvironment('E2E_RELAY', defaultValue: 1);
const capture = String.fromEnvironment('E2E_CAPTURE');
const syncOption = String.fromEnvironment('E2E_SYNC');
const watchCameras = bool.fromEnvironment('E2E_WATCH_CAMERAS');
const offerDisplay = bool.fromEnvironment('E2E_OFFER_DISPLAY');

/// The folder the host offers for sync: the same id on every member.
const syncFolderId = 'e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0';
const syncFolderLabel = 'E2E Sync';
const streamSize = String.fromEnvironment('E2E_H264_SIZE', defaultValue: '640x360');
const readyFile = String.fromEnvironment('E2E_READY_FILE');
const stopFile = String.fromEnvironment('E2E_STOP_FILE');
const serveSeconds = int.fromEnvironment('E2E_SERVE_SECONDS', defaultValue: 900);
const fps = 30;

/// A recorded stream played in a loop as the capture. Its first unit is a
/// keyframe, so the loop restarts cleanly, and a keyframe request skips ahead
/// to the next one.
class RecordedSource extends VideoSource {
  RecordedSource(this.units, this.size, {this.names = const []});

  final List<CaptureUnit> units;
  final Size size;

  /// What it reports as its sources: empty for a screen, the cameras' names
  /// for a camera.
  final List<String> names;

  @override
  Future<List<String>> sources() async => names;
  final _out = StreamController<CaptureUnit>.broadcast();
  Timer? _timer;
  int _at = 0;

  @override
  bool get supported => true;

  @override
  Stream<CaptureUnit> accessUnits() => _out.stream;

  @override
  Future<bool> requestConsent() async => true;

  @override
  Future<Size> start(
      {required int width,
      required int height,
      required int fps,
      required int bitrate}) async {
    _timer?.cancel();
    _at = 0;
    _timer = Timer.periodic(
        const Duration(microseconds: 1000000 ~/ 30), (_) => _next());
    return size;
  }

  void _next() {
    final unit = units[_at];
    _at = (_at + 1) % units.length;
    _out.add(CaptureUnit(
        unit.bytes, unit.keyframe, DateTime.now().microsecondsSinceEpoch));
  }

  @override
  Future<void> requestKeyframe() async {
    for (var i = 0; i < units.length; i++) {
      final at = (_at + i) % units.length;
      if (units[at].keyframe) {
        _at = at;
        return;
      }
    }
  }

  @override
  Future<void> setBitrate(int bitrate) async {}

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }
}

/// The file format of scripts/h264-sample.swift.
List<CaptureUnit> readUnits(Uint8List data) {
  final units = <CaptureUnit>[];
  final view = ByteData.sublistView(data);
  var at = 0;
  while (at + 5 <= data.length) {
    final length = view.getUint32(at);
    final keyframe = data[at + 4] == 1;
    at += 5;
    if (at + length > data.length) break;
    units.add(
        CaptureUnit(Uint8List.sublistView(data, at, at + length), keyframe, 0));
    at += length;
  }
  return units;
}

/// Watches `dev`'s camera for six seconds and writes what arrived to
/// camera-seen.txt in the share.
Future<void> watchCamera(ScreenViewer viewer, String dev, String shareDir) async {
  var units = 0, keyframes = 0, bytes = 0;
  var firstIsKeyframe = false, firstHasParameterSets = false;
  final sub = viewer.units.listen((u) {
    if (units == 0) {
      firstIsKeyframe = u.keyframe;
      // An SPS (NAL type 7) right behind the first start code.
      final b = u.bytes;
      firstHasParameterSets = b.length > 4 &&
          b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1 && (b[4] & 0x1F) == 7;
    }
    units++;
    if (u.keyframe) keyframes++;
    bytes += u.bytes.length;
  });
  viewer.request(dev, wantControl: false, maxWidth: 1280, maxFps: 30);
  // Up to ten seconds to start, then six of watching.
  for (var i = 0; i < 50 && viewer.state != ViewerState.active; i++) {
    if (viewer.state == ViewerState.failed) break;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final started = viewer.state == ViewerState.active;
  if (started) await Future<void>.delayed(const Duration(seconds: 6));
  final report = 'state=${viewer.state.name} size=${viewer.width}x${viewer.height} '
      'units=$units keyframes=$keyframes bytes=$bytes '
      'firstIsKeyframe=$firstIsKeyframe firstHasParameterSets=$firstHasParameterSets '
      'cameras=${viewer.cameras.join('|')} error=${viewer.error}';
  viewer.stop();
  await sub.cancel();
  // ignore: avoid_print
  print('E2E_HOST camera $report');
  await File('$shareDir/camera-seen.txt').writeAsString(report);
}

Future<Uint8List> fetchStream(String url) async {
  final http = HttpClient();
  try {
    final response = await (await http.getUrl(Uri.parse(url))).close();
    if (response.statusCode != 200) {
      fail('GET $url answered ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await response.forEach(bytes.add);
    return bytes.takeBytes();
  } finally {
    http.close();
  }
}

/// Reads from-phone.txt out of the "Phone" share of each connected peer that
/// offers one and lets this host read it, into this host's own share.
Future<void> fetchFromPhones(Session session, StorageClient client,
    String shareDir, Set<String> done) async {
  for (final p in session.peers.values.toList()) {
    if (p.stateCode != 3 || !p.hasHello || done.contains(p.devId)) continue;
    if (!p.services.contains(Services.storage) ||
        !p.grantedToMe.contains(Perm.storageRead)) {
      continue;
    }
    try {
      final root = await client.list(p.devId, '/');
      if (!root.entries.any((e) => e.name == 'Phone')) continue;
      final phone = await client.list(p.devId, '/Phone');
      if (!phone.entries.any((e) => e.name == 'from-phone.txt')) continue;
      done.add(p.devId);
      final local = '$shareDir/fetched-from-phone.txt';
      for (final old in [File(local), File('$local.ucpart')]) {
        if (old.existsSync()) old.deleteSync();
      }
      client.download(p.devId, '/Phone/from-phone.txt', local);
    } on Object catch (e) {
      stderr.writeln('reading ${p.displayName}: $e');
    }
  }
}

void main() {
  if (server.isEmpty || topic.isEmpty) {
    test('E2E host (skipped: run through scripts/e2e-ios.sh)', () {},
        skip: 'E2E_SERVER / E2E_TOPIC not set');
    return;
  }

  test('serve a share and a recorded screen until told to stop', serveHost,
      timeout: Timeout.none);
}

/// Joins the topic and serves until told to stop or the time is up. The body
/// of the test above, and of integration_test/device_host_test.dart.
Future<void> serveHost() async {
  {
    final creds = TopicCreds.parse(topic)!;
    final stateDir = await Directory.systemTemp.createTemp('uc-e2e-host');
    final identity = await Identity.loadOrCreate('${stateDir.path}/identity');
    final session = Session()..identity = identity;
    // print, not stderr: on a device only what is printed comes back.
    // ignore: avoid_print
    session.logLines.listen((line) => print('E2E_HOST log $line'));

    final services = <String>[];
    StorageClient? client;
    final fetched = <String>{}; // peers whose share has been read
    var shareDir = shareOption;
    if (shareDir == '@temp') {
      shareDir = '${Directory.systemTemp.path}/uc-e2e-host-share';
      await Directory(shareDir).create(recursive: true);
      await File('$shareDir/hello.txt').writeAsString('hello from the desk');
    }
    var syncDir = syncOption;
    if (syncDir == '@temp') {
      syncDir = '${Directory.systemTemp.path}/uc-e2e-host-sync';
    }
    if (syncDir.isNotEmpty) {
      final dir = Directory(syncDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      await dir.create(recursive: true);
      await File('$syncDir/from-host.txt').writeAsString('synced from the host');
    }
    if (shareDir.isNotEmpty) {
      await Directory(shareDir).create(recursive: true);
      StorageOfferer(session)
        ..offered = true
        ..shares = [
          SharedFolder('Docs', shareDir),
          if (syncDir.isNotEmpty) SharedFolder('Synced', syncDir, readOnly: true),
        ];
      client = StorageClient(session);
      services.add(Services.storage);
    }
    SyncClient? sync;
    if (syncDir.isNotEmpty) {
      // The wiring the app does in AppState._startSync, with every proven
      // peer made a member of the one folder as it appears.
      final members = <String, Grant>{};
      final engine = sync = SyncClient(
        sendControl: (dev, msg) => session.sendControl(dev, msg),
        sendData: (dev, id, bytes) =>
            session.sendFrame(dev, MessageKind.syncData, id, bytes),
        peerKey: (dev) {
          final p = session.peers[dev];
          return p != null && p.identityState == 'verified' ? p.identityKey : null;
        },
        offersTo: (dev) => true,
        connectedSince: (dev) => session.peers[dev]?.connectedAt ?? -1,
        myKeyHex: identity.publicKeyHex,
        stateDir: '${stateDir.path}/sync',
        // ignore: avoid_print
        onError: (m) => print('E2E_HOST sync worker: $m'),
      );
      await engine.start();
      void offer() => engine.setFolders([
            FolderConfig(
                id: syncFolderId,
                label: syncFolderLabel,
                path: syncDir,
                peers: {...members}),
          ]);
      session.addControlHandler(engine.handleControl);
      session.setFrameHandler(MessageKind.syncData, engine.handleData);
      session.addIdentityHandler((dev) {
        final key = session.peers[dev]?.identityKey ?? '';
        if (key.isNotEmpty && !members.containsKey(key)) {
          members[key] = const Grant(receive: true, contribute: true);
          offer();
        }
        engine.peerUp(dev);
      });
      session.addPeerStateHandler((dev, state) {
        if (state == ucPeerClosed || state == ucPeerFailed) engine.peerGone(dev);
      });
      offer();
    }
    // The extended display this host asks peers to show: its own handler
    // first, for the answers to dsp.request, then a screen host under dsp.*
    // for the session itself.
    final displayAsked = <String, int>{}; // peer -> request id
    ScreenHost? displayHost;
    if (offerDisplay && (streamFile.isNotEmpty || streamUrl.isNotEmpty)) {
      final wh = streamSize.split('x').map(double.parse).toList();
      final source = RecordedSource(
          readUnits(streamFile.isNotEmpty
              ? await File(streamFile).readAsBytes()
              : await fetchStream(streamUrl)),
          Size(wh[0], wh[1]));
      session.addControlHandler((dev, msg) {
        final t = msg['t'];
        if (t != 'dsp.wait' && t != 'dsp.err' && t != 'dsp.accept') return false;
        final request = msg['request'] is num ? (msg['request'] as num).toInt() : 0;
        if (request == 0 || displayAsked[dev] != request) return true;
        // ignore: avoid_print
        print('E2E_HOST display ${msg['t']} $msg');
        if (shareDir.isNotEmpty) {
          File('$shareDir/display-asked.txt').writeAsStringSync('$msg');
        }
        if (t == 'dsp.accept') {
          final maxWidth = msg['maxWidth'] is num ? (msg['maxWidth'] as num).toInt() : 1920;
          final maxFps = msg['maxFps'] is num ? (msg['maxFps'] as num).toInt() : 60;
          unawaited(displayHost!
              .startUnasked(dev, request, maxWidth: maxWidth, maxFps: maxFps));
        }
        return true;
      });
      displayHost = ScreenHost(session, source, RemoteInput(),
          askConsent: (dev, name,
                  {bool control = false, bool camera = false}) async =>
              true,
          prefix: 'dsp',
          videoKind: 4,
          viewPerm: Perm.displayShow,
          directPerm: Perm.displayDirect)
        ..offered = true;
    }
    var nextDisplayRequest = 1;

    if (capture == 'camera') {
      // The device's camera through its real encoder, as AppState.cameraHost
      // offers it (in the iOS simulator: the simulated camera).
      final camera = CameraCaptureController();
      camera.allCameras = await camera.cameras();
      ScreenHost(session, camera, RemoteInput(),
              askConsent: (dev, name,
                      {bool control = false, bool camera = false}) async =>
                  true,
              prefix: 'cam',
              videoKind: 3,
              viewPerm: Perm.cameraView,
              directPerm: Perm.cameraDirect)
          .offered = true;
      services.add(Services.camera);
    } else if (capture == 'screen') {
      ScreenHost(session, CaptureController(), RemoteInput(),
              askConsent: (dev, name,
                      {bool control = false, bool camera = false}) async =>
                  true)
          .offered = true;
      services.add(Services.screen);
    } else if (streamFile.isNotEmpty || streamUrl.isNotEmpty) {
      final units = readUnits(streamFile.isNotEmpty
          ? await File(streamFile).readAsBytes()
          : await fetchStream(streamUrl));
      if (units.isEmpty || !units.first.keyframe) {
        fail('$streamFile$streamUrl is not a stream from scripts/h264-sample.swift');
      }
      final wh = streamSize.split('x').map(double.parse).toList();
      final size = Size(wh[0], wh[1]);
      Future<bool> allow(String dev, String name,
              {bool control = false, bool camera = false}) async =>
          true;
      ScreenHost(session, RecordedSource(units, size), RemoteInput(),
              askConsent: allow)
          .offered = true;
      services.add(Services.screen);
      // The camera is the same host under its own prefix and video kind, as in
      // the app (AppState.cameraHost).
      ScreenHost(session,
              RecordedSource(units, size, names: const ['Test camera']),
              RemoteInput(),
              askConsent: allow,
              prefix: 'cam',
              videoKind: 3,
              viewPerm: Perm.cameraView,
              directPerm: Perm.cameraDirect)
          .offered = true;
      services.add(Services.camera);
    }
    session.setLocalHello(
        Hello(name: 'E2E Host', os: 'macos', services: services));
    session.setAccessPolicy(AccessPolicy(defaults: {
      Perm.storageObserve,
      Perm.storageRead,
      Perm.storageUpload,
      Perm.storageWrite,
      Perm.screenView,
      Perm.screenDirect,
      Perm.cameraView,
      Perm.cameraDirect,
      Perm.syncOffer,
      Perm.syncReceive,
    }));

    await session.start(
        SessionOptions(server: server, creds: creds, relayMode: relayMode));

    final cameraViewer =
        watchCameras && shareDir.isNotEmpty ? ScreenViewer(session, prefix: 'cam') : null;
    final camerasSeen = <String>{};
    var watching = false;

    final deadline = DateTime.now().add(const Duration(seconds: serveSeconds));
    var announced = false;
    while (DateTime.now().isBefore(deadline)) {
      if (!announced && session.selfId != null) {
        announced = true;
        if (readyFile.isNotEmpty) {
          await File(readyFile).writeAsString('READY ${session.selfId}\n');
        }
        // ignore: avoid_print
        print('E2E_HOST READY ${session.selfId}');
      }
      if (stopFile.isNotEmpty && File(stopFile).existsSync()) break;
      if (displayHost != null) {
        for (final p in session.peers.values.toList()) {
          if (p.stateCode == 3 &&
              p.identityState == 'verified' &&
              p.services.contains(Services.display) &&
              !displayAsked.containsKey(p.devId)) {
            final request = nextDisplayRequest++;
            displayAsked[p.devId] = request;
            // ignore: avoid_print
            print('E2E_HOST display asking ${p.displayName}');
            session.sendControl(p.devId, {
              't': 'dsp.request',
              'request': request,
              'mode': 'match',
              'codecs': const ['h264'],
            });
          }
        }
      }
      if (cameraViewer != null && !watching) {
        for (final p in session.peers.values.toList()) {
          if (p.stateCode == 3 &&
              p.identityState == 'verified' &&
              p.services.contains(Services.camera) &&
              p.grantedToMe.contains(Perm.cameraView) &&
              camerasSeen.add(p.devId)) {
            watching = true;
            unawaited(watchCamera(cameraViewer, p.devId, shareDir)
                .whenComplete(() => watching = false));
            break;
          }
        }
      }
      if (client != null) {
        // Bounded: a peer that leaves mid-request must not hold the host up.
        await fetchFromPhones(session, client, shareDir, fetched)
            .timeout(const Duration(seconds: 20), onTimeout: () {});
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // ignore: avoid_print
    print('E2E_HOST serving ended');
    await sync?.dispose().timeout(const Duration(seconds: 5), onTimeout: () {});
    await session.dispose().timeout(const Duration(seconds: 10), onTimeout: () {
      // ignore: avoid_print
      print('E2E_HOST the session did not shut down in 10 s');
    });
    await stateDir.delete(recursive: true);
    // ignore: avoid_print
    print('E2E_HOST done');
  }
}
