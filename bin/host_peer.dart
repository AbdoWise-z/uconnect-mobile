// A headless uConnect peer for E2E tests: joins a topic, offers a storage
// share with every permission granted by default, and serves until killed.
// The Android integration test talks to it through the rendezvous relay.
//
//   dart run bin/host_peer.dart <server> <uconn://...> <share dir>
//
// Prints "READY <selfId>" once published. Pure Dart (no Flutter imports), so
// it runs with the plain Dart VM; point UCONNECT_C_LIBRARY at a host build of
// uconnect_c first.

import 'dart:async';
import 'dart:io';

import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/core/permissions.dart';
import 'package:uconnect_mobile/core/session.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';
import 'package:uconnect_mobile/core/storage/storage_offerer.dart';
import 'package:uconnect_mobile/core/wire.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: host_peer <server> <uconn://...> <share dir>');
    exit(2);
  }
  final server = args[0];
  final creds = TopicCreds.parse(args[1]);
  if (creds == null) {
    stderr.writeln('bad invite link');
    exit(2);
  }
  final shareDir = Directory(args[2]);
  await shareDir.create(recursive: true);

  final stateDir = await Directory.systemTemp.createTemp('uc-host-peer');
  final identity = await Identity.loadOrCreate('${stateDir.path}/identity');
  final session = Session()..identity = identity;
  session.logLines.listen(stderr.writeln);
  StorageOfferer(session)
    ..offered = true
    ..shares = [SharedFolder('Docs', shareDir.path)];
  StorageClient(session);
  session.setLocalHello(
      Hello(name: 'E2E Host', os: 'windows', services: const ['storage']));
  session.setAccessPolicy(AccessPolicy(defaults: {
    Perm.storageObserve,
    Perm.storageRead,
    Perm.storageUpload,
    Perm.storageWrite,
  }));

  await session.start(
      SessionOptions(server: server, creds: creds, forceRelay: true));

  var announced = false;
  session.changed.listen((_) {
    if (!announced && session.selfId != null) {
      announced = true;
      stdout.writeln('READY ${session.selfId}');
    }
  });

  // Serve until killed.
  await Completer<void>().future;
}
