// SyncClient: the engine on its own isolate, driven through the client as the
// app drives it. Two clients joined by in-process links sync a folder; the
// listings come back as futures; and the main isolate stays free while a
// folder of many files syncs.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/sync/sync_client.dart';
import 'package:uconnect_mobile/core/sync/sync_folder.dart';
import 'package:uconnect_mobile/core/sync/sync_model.dart';

const kFolder = '0123456789abcdef0123456789abcdef';
const kGrantAll = Grant(receive: true, contribute: true);

class Node {
  Node(this.name, this.key, this.dev, this.root);
  final String name;
  final String key;
  final String dev;
  final String root;
  late final SyncClient client;
  Map<String, Object?> status = {};
  final events = <String>[];
  final errors = <String>[];
}

class Net {
  Net() : dir = Directory.systemTemp.createTempSync('uconnect_sync_client');

  final Directory dir;
  final nodes = <Node>[];
  final links = <String>{};
  final since = <String, int>{};

  static String pair(int a, int b) => '${min(a, b)}-${max(a, b)}';

  Node add(String name) {
    final index = nodes.length;
    final key = bytesToHex(List.filled(32, 0x61 + index));
    final root = '${dir.path}${Platform.pathSeparator}$name';
    Directory(root).createSync(recursive: true);
    final n = Node(name, key, 'dev$index', root);
    n.client = SyncClient(
      sendControl: (to, msg) => deliver(index, to, control: msg),
      sendData: (to, id, bytes) => deliver(index, to, id: id, data: bytes),
      peerKey: (d) {
        final other = indexOf(d);
        return other >= 0 && linked(index, other) ? nodes[other].key : null;
      },
      connectedSince: (d) {
        final other = indexOf(d);
        return other >= 0 ? since[pair(index, other)] ?? -1 : -1;
      },
      myKeyHex: key,
      stateDir: '${dir.path}${Platform.pathSeparator}$name-state',
      onError: n.errors.add,
    );
    n.client.configure(const SyncSettings(scanIntervalMs: 150, stableAfterMs: 0));
    n.client.folderChanged.listen((id) => n.status = n.client.folderStatus(id));
    n.client.events.listen((e) => n.events.add('${e.path} ${e.kind}'));
    unawaited(n.client.start());
    nodes.add(n);
    return n;
  }

  int indexOf(String dev) => nodes.indexWhere((n) => n.dev == dev);
  bool linked(int a, int b) => links.contains(pair(a, b));

  // As the session would: a message is taken now and handed over on a later
  // turn; every fourth data frame is refused once, as a full queue would.
  int _refused = 0;
  bool deliver(int from, String to,
      {Map<String, Object?>? control, int id = 0, Uint8List? data}) {
    final dest = indexOf(to);
    if (dest < 0 || !linked(from, dest)) return false;
    if (data != null && (++_refused % 4 == 0)) return false;
    final bytes = data == null ? null : Uint8List.fromList(data);
    final fromDev = nodes[from].dev;
    Timer.run(() {
      if (!linked(from, dest)) return;
      if (control != null) {
        nodes[dest].client.handleControl(fromDev, control);
      } else {
        nodes[dest].client.handleData(fromDev, id, bytes!);
      }
    });
    return true;
  }

  void link(int a, int b) {
    links.add(pair(a, b));
    since[pair(a, b)] = DateTime.now().millisecondsSinceEpoch;
    nodes[a].client.peerUp(nodes[b].dev);
    nodes[b].client.peerUp(nodes[a].dev);
  }

  FolderConfig config(int i) => FolderConfig(
        id: kFolder,
        label: 'Shared',
        path: nodes[i].root,
        peers: {
          for (var j = 0; j < nodes.length; j++)
            if (j != i) nodes[j].key: kGrantAll
        },
      );

  void join(int i) => nodes[i].client.setFolders([config(i)]);

  Future<void> dispose() async {
    for (final n in nodes) {
      await n.client.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // a scan isolate may still hold a handle for a moment
    }
  }
}

Future<void> until(FutureOr<bool> Function() cond, {int ms = 20000}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < ms) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out waiting');
}

void write(String root, String rel, List<int> bytes) {
  final f = File('$root${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}

bool has(String root, String rel, List<int> bytes) {
  final f = File('$root${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
  if (!f.existsSync()) return false;
  final got = f.readAsBytesSync();
  if (got.length != bytes.length) return false;
  for (var i = 0; i < got.length; i++) {
    if (got[i] != bytes[i]) return false;
  }
  return true;
}

void main() {
  late Net net;
  setUp(() => net = Net());
  tearDown(() => net.dispose());

  test('syncs through the worker and answers the listings', () async {
    final alice = net.add('alice');
    final bob = net.add('bob');
    final a = List<int>.generate(3000, (i) => i % 251);
    final b = List<int>.generate(200 * 1024, (i) => (i * 7) % 253);
    write(alice.root, 'a.txt', a);
    write(alice.root, 'sub/b.bin', b);
    net.join(0);
    net.join(1);
    net.link(0, 1);

    await until(() => has(bob.root, 'a.txt', a) && has(bob.root, 'sub/b.bin', b));
    await until(() async {
      final rows = await bob.client.files(kFolder);
      return rows.length == 3 && rows.every((r) => r['state'] == 'synced');
    });
    // The status is the worker's last report; it follows shortly.
    await until(() => bob.status['state'] != 'syncing' && bob.status['files'] == 2);
    final members = (bob.status['members'] as List).cast<Map>();
    expect(members.single['online'], true);

    final info = await bob.client.fileInfo(kFolder, 'sub/b.bin');
    expect(info['size'], b.length);
    expect((info['holders'] as List).length, 1);
    expect(bob.client.transfers(), isEmpty);

    // A change goes back the other way.
    final a2 = [...a, 1, 2, 3];
    write(bob.root, 'a.txt', a2);
    await until(() => has(alice.root, 'a.txt', a2));
    expect(alice.errors, isEmpty);
    expect(bob.errors, isEmpty);
  });

  test('rules and kept files round-trip', () async {
    final alice = net.add('alice');
    final bob = net.add('bob');
    write(alice.root, 'keep.txt', [1, 2, 3]);
    write(alice.root, 'drop.tmp', [4, 5, 6]);
    write(alice.root, 'gone.txt', [7, 8, 9]);
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await until(() =>
        has(bob.root, 'drop.tmp', [4, 5, 6]) && has(bob.root, 'gone.txt', [7, 8, 9]));

    expect(await bob.client.rulesText(kFolder, false), '');
    final preview = await bob.client.previewRules(kFolder, false, '*.tmp\n', probe: 'x.tmp');
    expect(preview['stop'], 1);
    expect((preview['probe'] as Map)['excluded'], true);
    expect(await bob.client.saveRules(kFolder, false, '*.tmp\n'), true);
    expect(await bob.client.rulesText(kFolder, false), '*.tmp\n');
    // .syncignore syncs to alice, and drop.tmp leaves the index on both.
    await until(() => has(alice.root, '.syncignore', '*.tmp\n'.codeUnits));
    await until(() async {
      final rows = await alice.client.files(kFolder);
      final row = rows.where((r) => r['path'] == 'drop.tmp').firstOrNull;
      return row != null && row['state'] == 'ignored';
    });
    expect(await bob.client.addRule(kFolder, true, 'keep.txt'), true);
    expect(await bob.client.rulesText(kFolder, true), contains('keep.txt'));

    // A delete elsewhere keeps the file here, restorable.
    File('${alice.root}${Platform.pathSeparator}gone.txt').deleteSync();
    await until(() async => (await bob.client.keptFiles(kFolder)).isNotEmpty, ms: 30000);
    final kept = await bob.client.keptFiles(kFolder);
    expect(kept.single['path'], 'gone.txt');
    expect(await bob.client.restoreKept(kFolder, '${kept.single['kept']}'), true);
    expect(await bob.client.keptFiles(kFolder), isEmpty);
    await until(() => has(bob.root, 'gone.txt', [7, 8, 9]));
  });

  test('the UI isolate stays free while a folder of many files syncs', () async {
    final alice = net.add('alice');
    final bob = net.add('bob');
    final rnd = Random(3);
    const count = 1200;
    for (var i = 0; i < count; i++) {
      final bytes = Uint8List(100 + rnd.nextInt(3000));
      for (var j = 0; j < bytes.length; j++) {
        bytes[j] = rnd.nextInt(256);
      }
      write(alice.root, 'd${i % 30}/f$i.bin', bytes);
    }
    final big = Uint8List(12 * 1024 * 1024);
    for (var j = 0; j < big.length; j += 4096) {
      big[j] = rnd.nextInt(256);
    }
    write(alice.root, 'big.bin', big);

    // A 1 ms timer: every late firing is time this isolate was busy.
    var worst = 0;
    var over100 = 0;
    var last = DateTime.now().millisecondsSinceEpoch;
    final meter = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final gap = now - last - 1;
      last = now;
      if (gap > worst) worst = gap;
      if (gap > 100) over100++;
    });
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await until(() {
      final st = bob.status;
      return st['files'] == count + 1 && st['needFiles'] == 0 && st['state'] != 'syncing';
    }, ms: 180000);
    // What the files page asks for, with the engine busy or not.
    final sw = Stopwatch()..start();
    final rows = await bob.client.files(kFolder);
    final listMs = sw.elapsedMilliseconds;
    meter.cancel();
    expect(rows.length, greaterThanOrEqualTo(count + 1));
    // ignore: avoid_print
    print('worst stall $worst ms, >100 ms: $over100, files() took $listMs ms');
    expect(worst, lessThan(250));
    expect(over100, lessThan(3));
    expect(alice.errors, isEmpty);
    expect(bob.errors, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('stops cleanly with work queued', () async {
    final alice = net.add('alice');
    net.add('bob');
    write(alice.root, 'x.txt', [1]);
    net.join(0);
    net.join(1);
    net.link(0, 1);
    final pending = alice.client
        .files(kFolder)
        .then((_) => 'answered', onError: (Object _) => 'stopped');
    await alice.client.dispose();
    expect(await pending, anyOf('answered', 'stopped'));
    // Nothing more goes to the worker, and nothing more comes from it.
    alice.client.rescan(kFolder);
    expect(await alice.client.files(kFolder).then((_) => 'answered', onError: (Object _) => 'stopped'),
        'stopped');
  });
}
