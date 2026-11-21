// A headless uConnect peer for the on-device E2E tests that also shares a
// "screen" and a "camera": like bin/host_peer.dart it joins a topic and serves
// a storage share with everything granted, and on top of that it offers screen
// and camera sharing, playing a recorded H.264 stream
// (scripts/h264-sample.swift) in a loop as if it were the live capture. A
// device can then watch either with no real screen, camera, capture permission
// or window involved.
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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/core/screen/remote_input.dart';
import 'package:uconnect_mobile/core/screen/screen_capture.dart';
import 'package:uconnect_mobile/core/screen/screen_host.dart';
import 'package:uconnect_mobile/core/session.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';
import 'package:uconnect_mobile/core/storage/storage_offerer.dart';
import 'package:uconnect_mobile/core/wire.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

const server = String.fromEnvironment('E2E_SERVER');
const topic = String.fromEnvironment('E2E_TOPIC');
const shareDir = String.fromEnvironment('E2E_SHARE');
const streamFile = String.fromEnvironment('E2E_H264_FILE');
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

/// Reads from-phone.txt out of the "Phone" share of each connected peer that
/// offers one and lets this host read it, into this host's own share.
Future<void> fetchFromPhones(
    Session session, StorageClient client, Set<String> done) async {
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

  test('serve a share and a recorded screen until told to stop', () async {
    final creds = TopicCreds.parse(topic)!;
    final stateDir = await Directory.systemTemp.createTemp('uc-e2e-host');
    final identity = await Identity.loadOrCreate('${stateDir.path}/identity');
    final session = Session()..identity = identity;
    session.logLines.listen(stderr.writeln);

    final services = <String>[];
    StorageClient? client;
    final fetched = <String>{}; // peers whose share has been read
    if (shareDir.isNotEmpty) {
      await Directory(shareDir).create(recursive: true);
      StorageOfferer(session)
        ..offered = true
        ..shares = [SharedFolder('Docs', shareDir)];
      client = StorageClient(session);
      services.add(Services.storage);
    }
    if (streamFile.isNotEmpty) {
      final units = readUnits(await File(streamFile).readAsBytes());
      if (units.isEmpty || !units.first.keyframe) {
        fail('$streamFile is not a stream from scripts/h264-sample.swift');
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
    }));

    await session.start(
        SessionOptions(server: server, creds: creds, relayMode: 1));

    final deadline = DateTime.now().add(const Duration(seconds: serveSeconds));
    var announced = false;
    while (DateTime.now().isBefore(deadline)) {
      if (!announced && session.selfId != null) {
        announced = true;
        if (readyFile.isNotEmpty) {
          await File(readyFile).writeAsString('READY ${session.selfId}\n');
        }
      }
      if (stopFile.isNotEmpty && File(stopFile).existsSync()) break;
      if (client != null) await fetchFromPhones(session, client, fetched);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await session.dispose();
    await stateDir.delete(recursive: true);
  }, timeout: Timeout.none);
}
