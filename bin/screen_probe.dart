// Headless screen-sharing viewer for verifying the host (phone) side: joins
// the topic with a given identity seed (so a phone that trusts that key grants
// it screen.view), requests a peer's screen, and writes the reassembled H.264
// access units to a file for inspection (e.g. ffprobe). Pure Dart; point
// UCONNECT_C_LIBRARY at a host build of uconnect_c first.
//
//   dart run bin/screen_probe.dart <server> <uconn://...> <seedHex> <out.h264> [seconds]

import 'dart:async';
import 'dart:io';

import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/core/screen/screen_viewer.dart';
import 'package:uconnect_mobile/core/session.dart';
import 'package:uconnect_mobile/core/wire.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('usage: screen_probe <server> <uconn://...> <seedHex> <out> [seconds]');
    exit(2);
  }
  final server = args[0];
  final creds = TopicCreds.parse(args[1])!;
  final seed = hexToBytes(args[2])!;
  final out = File(args[3]).openWrite();
  final seconds = args.length > 4 ? int.parse(args[4]) : 12;

  final identity = await Identity.fromSeed(seed);
  final session = Session()..identity = identity;
  session.logLines.listen(stderr.writeln);
  session.setLocalHello(Hello(name: 'Screen Probe', os: 'windows', services: const []));
  session.setAccessPolicy(AccessPolicy());
  await session.start(SessionOptions(server: server, creds: creds));

  // Wait for a connected peer that offers screen.
  String? host;
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (host == null && DateTime.now().isBefore(deadline)) {
    for (final p in session.peers.values) {
      if (p.stateCode == 3 &&
          p.identityState == 'verified' &&
          p.services.contains('screen')) {
        host = p.devId;
        break;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  if (host == null) {
    stderr.writeln('no peer offering screen appeared');
    await session.dispose();
    exit(1);
  }
  // Let both sides finish verifying each other's identity so the host's
  // permission check (which keys off our proven identity) is in effect.
  await Future<void>.delayed(const Duration(seconds: 3));
  stderr.writeln('requesting screen from $host');

  final viewer = ScreenViewer(session);
  var frames = 0;
  var keyframes = 0;
  var bytes = 0;
  viewer.units.listen((u) {
    frames++;
    if (u.keyframe) keyframes++;
    bytes += u.bytes.length;
    out.add(u.bytes);
  });
  var lastState = viewer.state;
  viewer.changed.listen((_) {
    if (viewer.state != lastState) {
      lastState = viewer.state;
      stderr.writeln('viewer state -> ${viewer.state}'
          '${viewer.state == ViewerState.active ? ' ${viewer.width}x${viewer.height} @${viewer.fps}fps' : ''}'
          '${viewer.error.isNotEmpty ? ' error=${viewer.error}' : ''}');
    }
  });
  // Optional control test: UCONNECT_PROBE_TAP="x,y" (normalized 0..1) requests
  // control and taps there once control is granted, to verify input injection.
  final tap = Platform.environment['UCONNECT_PROBE_TAP'];
  viewer.request(host, wantControl: false, maxWidth: 1280, maxFps: 30);

  var tapped = false;
  for (var s = 0; s < seconds; s++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    stderr.writeln('t=${s + 1}s state=${viewer.state} frames=$frames '
        'control=${viewer.controlOn} '
        'path=${session.node?.datagramPath(session.topicId, host)}');
    if (tap != null && viewer.state == ViewerState.active && !tapped) {
      if (!viewer.controlOn) {
        viewer.requestControl(true);
      } else {
        final parts = tap.split(',');
        final nx = double.parse(parts[0]);
        final ny = double.parse(parts[1]);
        stderr.writeln('>>> tapping at ($nx,$ny)');
        viewer.sendPointer(nx, ny, 1); // press
        await Future<void>.delayed(const Duration(milliseconds: 80));
        viewer.sendPointer(nx, ny, 0); // release
        tapped = true;
      }
    }
  }
  viewer.stop();
  await out.flush();
  await out.close();
  // ignore: avoid_print
  print('frames=$frames keyframes=$keyframes bytes=$bytes '
      'size=${viewer.width}x${viewer.height}');
  await viewer.dispose();
  await session.dispose();
  exit(0);
}
