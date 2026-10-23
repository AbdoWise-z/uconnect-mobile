// Several SyncService instances joined by in-process links that can be cut and
// restored, each syncing its own temporary folder. A port of uconnect-desktop's
// tests/SyncServiceTest.cpp.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/sync/sync_folder.dart';
import 'package:uconnect_mobile/core/sync/sync_model.dart';
import 'package:uconnect_mobile/core/sync/sync_scanner.dart';
import 'package:uconnect_mobile/core/sync/sync_service.dart';

const kFolder = '0123456789abcdef0123456789abcdef';
const kWindow = 8;
const kGrantAll = Grant(receive: true, contribute: true);

class Node {
  Node(this.name, this.key, this.dev, this.root);
  final String name;
  final String key; // identity key, hex
  final String dev;
  final String root;
  late final SyncService svc;
  Map<String, Object?> status = {};
  final events = <String>[];
}

class Net {
  Net() : dir = Directory.systemTemp.createTempSync('uconnect_sync');

  final Directory dir;
  final nodes = <Node>[];
  final links = <String>{};
  final since = <String, int>{};
  final inFlight = <String, int>{};
  int dataBytes = 0; // block data delivered, all links

  static String pair(int a, int b) => '${min(a, b)}-${max(a, b)}';

  Node add(String name) {
    final index = nodes.length;
    final key = bytesToHex(List.filled(32, 0x61 + index));
    final root = '${dir.path}${Platform.pathSeparator}$name';
    Directory(root).createSync(recursive: true);
    final n = Node(name, key, 'dev$index', root);
    n.svc = SyncService(
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
    )
      ..scanIntervalMs = 150
      ..stableAfterMs = 0;
    n.svc.folderChanged.listen((id) => n.status = n.svc.folderStatus(id));
    n.svc.events.listen((e) => n.events.add('${e.path} ${e.kind}'));
    nodes.add(n);
    return n;
  }

  int indexOf(String dev) => nodes.indexWhere((n) => n.dev == dev);
  bool linked(int a, int b) => links.contains(pair(a, b));

  bool deliver(int from, String to,
      {Map<String, Object?>? control, int id = 0, Uint8List? data}) {
    final dest = indexOf(to);
    if (dest < 0 || !linked(from, dest)) return false;
    final k = '$from>$dest';
    if ((inFlight[k] ?? 0) >= kWindow) return false;
    inFlight[k] = (inFlight[k] ?? 0) + 1;
    // As on the wire: the JSON is encoded and decoded, the bytes copied.
    final msg = control == null
        ? null
        : (jsonDecode(jsonEncode(control)) as Map).cast<String, Object?>();
    final bytes = data == null ? null : Uint8List.fromList(data);
    if (bytes != null) dataBytes += bytes.length;
    final fromDev = nodes[from].dev;
    Timer.run(() {
      inFlight[k] = inFlight[k]! - 1;
      if (!linked(from, dest)) return;
      if (msg != null) {
        nodes[dest].svc.handleControl(fromDev, msg);
      } else {
        nodes[dest].svc.handleData(fromDev, id, bytes!);
      }
    });
    return true;
  }

  // `when`: the connection's start time, to order "connected longest".
  void link(int a, int b, [int when = -1]) {
    links.add(pair(a, b));
    since[pair(a, b)] = when >= 0 ? when : DateTime.now().millisecondsSinceEpoch;
    nodes[a].svc.peerUp(nodes[b].dev);
    nodes[b].svc.peerUp(nodes[a].dev);
  }

  void unlink(int a, int b) {
    links.remove(pair(a, b));
    nodes[a].svc.peerGone(nodes[b].dev);
    nodes[b].svc.peerGone(nodes[a].dev);
  }

  // Everyone in the folder, everyone allowed both ways unless changed.
  FolderConfig config(int i, [Map<int, Grant> grants = const {}]) => FolderConfig(
        id: kFolder,
        label: 'Shared',
        path: nodes[i].root,
        peers: {
          for (var j = 0; j < nodes.length; j++)
            if (j != i) nodes[j].key: grants[j] ?? kGrantAll
        },
      );

  void join(int i, [Map<int, Grant> grants = const {}]) =>
      nodes[i].svc.setFolders([config(i, grants)]);

  Future<void> dispose() async {
    for (final n in nodes) {
      await n.svc.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // a scan isolate may still hold a handle for a moment
    }
  }
}

void write(String path, List<int> data) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(data, flush: true);
}

void writeText(String path, String text) => write(path, utf8.encode(text));

String contents(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return '<missing>';
  }
}

Uint8List bytesOf(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException {
    return Uint8List(0);
  }
}

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

int conflictsOf(Node n) => (n.status['conflicts'] as List?)?.length ?? 0;

List<String> filesIn(String dir) => [
      for (final e in Directory(dir).listSync())
        if (e is File) baseName(e.path)
    ];

Future<void> eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10), String? reason}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('timed out${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Net net;
  String at(int node, String rel) => joinPath(net.nodes[node].root, rel);

  setUp(() => net = Net());
  tearDown(() => net.dispose());

  test('syncs a new member and then changes', () async {
    net.add('alice');
    net.add('bob');
    final big = randomBytes(3 * 1024 * 1024 + 7, 1);
    writeText(at(0, 'a.txt'), 'alpha');
    writeText(at(0, 'sub/b.txt'), 'bravo');
    write(at(0, 'big.bin'), big);
    Directory(at(0, 'empty')).createSync();
    net.join(0);
    net.join(1);
    net.link(0, 1);

    await eventually(() => bytesEqual(bytesOf(at(1, 'big.bin')), big),
        timeout: const Duration(seconds: 20));
    await eventually(() => contents(at(1, 'a.txt')) == 'alpha');
    await eventually(() => contents(at(1, 'sub/b.txt')) == 'bravo');
    await eventually(() => Directory(at(1, 'empty')).existsSync());
    expect(
        Directory(at(1, ''))
            .listSync()
            .where((e) => baseName(e.path).startsWith(kPartPrefix)),
        isEmpty);

    // Back the other way: an edit, a delete and a new file.
    writeText(at(1, 'a.txt'), 'alpha, edited by bob');
    File(at(1, 'sub/b.txt')).deleteSync();
    writeText(at(1, 'new.txt'), 'from bob');
    await eventually(() => contents(at(0, 'a.txt')) == 'alpha, edited by bob');
    await eventually(() => !File(at(0, 'sub/b.txt')).existsSync());
    // Kept aside, not gone.
    final kept = filesIn(at(0, '.synctrash/sub'))
        .where((n) => n.startsWith('b~') && n.endsWith('.txt'))
        .toList();
    expect(kept.length, 1);
    expect(contents(at(0, '.synctrash/sub/${kept.first}')), 'bravo');
    await eventually(() => contents(at(0, 'new.txt')) == 'from bob');
    expect(conflictsOf(net.nodes[0]), 0);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('reuses blocks it already has', () async {
    net.add('alice');
    net.add('bob');
    final big = randomBytes(2 * 1024 * 1024, 2);
    write(at(0, 'big.bin'), big);
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => bytesEqual(bytesOf(at(1, 'big.bin')), big),
        timeout: const Duration(seconds: 20));

    // A rename, and a copy with one block changed, send (almost) nothing.
    net.dataBytes = 0;
    File(at(0, 'big.bin')).renameSync(at(0, 'moved.bin'));
    final edited = Uint8List.fromList(big)..[100] ^= 0x5a;
    write(at(0, 'copy.bin'), edited);
    await eventually(() => bytesEqual(bytesOf(at(1, 'moved.bin')), big));
    await eventually(() => bytesEqual(bytesOf(at(1, 'copy.bin')), edited));
    await eventually(() => !File(at(1, 'big.bin')).existsSync());
    expect(net.dataBytes, lessThanOrEqualTo(128 * 1024)); // one block
  }, timeout: const Timeout(Duration(seconds: 90)));

  // A rename moves the file in place: nothing fetched, nothing kept aside. A
  // change of case only is one too.
  test('renames in place', () async {
    net.add('alice');
    net.add('bob');
    final big = randomBytes(1024 * 1024, 3);
    write(at(0, 'big.bin'), big);
    writeText(at(0, 'report.txt'), 'report');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => bytesEqual(bytesOf(at(1, 'big.bin')), big));
    await eventually(() => contents(at(1, 'report.txt')) == 'report');

    net.dataBytes = 0;
    File(at(0, 'big.bin')).renameSync(at(0, 'moved.bin'));
    File(at(0, 'report.txt')).renameSync(at(0, 'step.tmp'));
    File(at(0, 'step.tmp')).renameSync(at(0, 'Report.txt'));
    await eventually(() => bytesEqual(bytesOf(at(1, 'moved.bin')), big));
    await eventually(() => filesIn(at(1, '')).contains('Report.txt'));
    expect(filesIn(at(1, '')).contains('report.txt'), isFalse);
    await eventually(() => !File(at(1, 'big.bin')).existsSync());
    expect(net.dataBytes, 0);
    expect(Directory(at(1, '.synctrash')).existsSync(), isFalse);
    await wait(500);
    expect(conflictsOf(net.nodes[1]), 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // Two devices made the same name in different case: the older one is
  // synced, the newer one stays where it is but is held back, and syncs once
  // the older one goes.
  test('names that clash wait for the older one', () async {
    net.add('alice');
    net.add('bob');
    writeText(at(0, 'Report.txt'), "alice's, older");
    writeText(at(1, 'report.txt'), "bob's, newer");
    File(at(0, 'Report.txt'))
        .setLastModifiedSync(DateTime.now().subtract(const Duration(days: 10)));
    net.join(0);
    net.join(1);
    await wait(600); // each has scanned its own
    net.link(0, 1);
    await eventually(() {
      for (final h in (net.nodes[1].status['held'] as List? ?? const [])) {
        final m = h as Map;
        if (m['path'] == 'report.txt' && m['reason'] == 'clash:Report.txt') {
          return true;
        }
      }
      return false;
    });
    await wait(800);
    expect(contents(at(0, 'Report.txt')), "alice's, older"); // nothing written over
    expect(contents(at(1, 'report.txt')), "bob's, newer");
    expect(filesIn(at(0, '')).contains('report.txt'), isFalse);

    // Alice's goes: Bob's syncs.
    File(at(0, 'Report.txt')).deleteSync();
    await eventually(() => contents(at(0, 'report.txt')) == "bob's, newer",
        timeout: const Duration(seconds: 15));
    expect(filesIn(at(0, '')).contains('report.txt'), isTrue);
    expect(contents(at(1, 'report.txt')), "bob's, newer");
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('does not sync names some member cannot hold', () async {
    net.add('alice');
    net.add('bob');
    // Windows cannot even create names like "notes: draft.txt"; the rule
    // shows on Unicode everywhere.
    final bad = Platform.isWindows ? 'café.txt' : 'notes: draft.txt';
    writeText(at(0, bad), 'x');
    writeText(at(0, 'fine.txt'), 'fine');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'fine.txt')) == 'fine');
    await eventually(() {
      for (final h in (net.nodes[0].status['held'] as List? ?? const [])) {
        if (((h as Map)['reason'] as String).startsWith('name:')) return true;
      }
      return false;
    });
    expect(filesIn(at(1, '')), ['fine.txt']);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('receive-only members do not change others', () async {
    net.add('alice');
    net.add('bob');
    writeText(at(0, 'doc.txt'), 'original');
    net.join(0, {1: const Grant(receive: true)}); // alice sends to bob, takes nothing from him
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'doc.txt')) == 'original');
    writeText(at(1, 'doc.txt'), "bob's change");
    writeText(at(1, 'bobs.txt'), 'bob');
    await wait(1500);
    expect(contents(at(0, 'doc.txt')), 'original');
    expect(File(at(0, 'bobs.txt')).existsSync(), isFalse);
    // Alice's own changes still reach him (his edit becomes a conflict there).
    writeText(at(0, 'more.txt'), 'more');
    await eventually(() => contents(at(1, 'more.txt')) == 'more');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('conflicts wait for their owners and settle everywhere', () async {
    net.add('alice');
    net.add('bob');
    writeText(at(0, 'plan.md'), 'v1');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'plan.md')) == 'v1');

    net.unlink(0, 1);
    writeText(at(0, 'plan.md'), "alice's version");
    writeText(at(1, 'plan.md'), "bob's longer version");
    await wait(600); // both scanned
    net.link(0, 1);
    await eventually(() => conflictsOf(net.nodes[0]) == 1);
    await eventually(() => conflictsOf(net.nodes[1]) == 1);
    final c = (net.nodes[0].status['conflicts'] as List).first as Map;
    expect(c['involved'], isTrue);
    expect(contents(at(0, 'plan.md')), "alice's version"); // nothing overwritten
    expect(contents(at(1, 'plan.md')), "bob's longer version");

    net.nodes[0].svc.resolveConflict(kFolder, 'plan.md', 'mine', '');
    await eventually(() => contents(at(1, 'plan.md')) == "alice's version");
    await eventually(() => conflictsOf(net.nodes[0]) == 0);
    await eventually(() => conflictsOf(net.nodes[1]) == 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('taking theirs fetches it', () async {
    net.add('alice');
    net.add('bob');
    writeText(at(0, 'plan.md'), 'v1');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'plan.md')) == 'v1');
    net.unlink(0, 1);
    writeText(at(0, 'plan.md'), "alice's version");
    writeText(at(1, 'plan.md'), "bob's longer version");
    await wait(600);
    net.link(0, 1);
    await eventually(() => conflictsOf(net.nodes[0]) == 1);
    net.nodes[0].svc.resolveConflict(kFolder, 'plan.md', 'theirs', net.nodes[1].key);
    await eventually(() => contents(at(0, 'plan.md')) == "bob's longer version");
    await eventually(() => conflictsOf(net.nodes[0]) == 0);
    await eventually(() => conflictsOf(net.nodes[1]) == 0);
    expect(contents(at(1, 'plan.md')), "bob's longer version");
    // Alice's own version, given up, is kept aside.
    final kept = filesIn(at(0, '.synctrash'))
        .where((n) => n.startsWith('plan~') && n.endsWith('.md'))
        .toList();
    expect(kept.length, 1);
    expect(contents(at(0, '.synctrash/${kept.first}')), "alice's version");
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('keeps deleted files for their time only', () async {
    net.add('alice');
    net.add('bob');
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final fresh = '.synctrash/fresh~$stamp.txt';
    writeText(at(0, '.synctrash/old~20200101-000000.txt'), 'old');
    writeText(at(0, '.synctrash/deep/older~20200101-000000'), 'older');
    writeText(at(0, fresh), 'fresh');
    writeText(at(0, 'a.txt'), 'alpha');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(
        () => !File(at(0, '.synctrash/old~20200101-000000.txt')).existsSync(),
        timeout: const Duration(seconds: 5));
    await eventually(() => !Directory(at(0, '.synctrash/deep')).existsSync()); // emptied folders go too
    expect(File(at(0, fresh)).existsSync(), isTrue);
    await eventually(() => contents(at(1, 'a.txt')) == 'alpha');
    expect(Directory(at(1, '.synctrash')).existsSync(), isFalse); // never synced
  }, timeout: const Timeout(Duration(seconds: 60)));

  // Dave did not edit and is behind both sides: he follows the one he has
  // been connected to longest, and says so.
  test('bystanders follow the longest connection', () async {
    net.add('bob');
    net.add('carol');
    net.add('dave');
    writeText(at(0, 'plan.md'), 'v1');
    net.join(0);
    net.join(1);
    net.join(2);
    net.link(0, 2);
    net.link(1, 2);
    await eventually(() => contents(at(1, 'plan.md')) == 'v1');
    await eventually(() => contents(at(2, 'plan.md')) == 'v1');

    net.unlink(0, 2);
    net.unlink(1, 2);
    writeText(at(0, 'plan.md'), "bob's");
    writeText(at(1, 'plan.md'), "carol's version");
    await wait(600);
    net.link(1, 2, 1000); // carol: connected since earlier
    net.link(0, 2, 5000);
    await eventually(() => contents(at(2, 'plan.md')) == "carol's version");
    await eventually(() {
      final told = net.nodes[2].events.join(';');
      return told.contains('plan.md following:${net.nodes[1].key}') ||
          told.contains('plan.md kept');
    });
    await eventually(() => conflictsOf(net.nodes[0]) == 1); // still bob's to decide
    expect(contents(at(0, 'plan.md')), "bob's");
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('follows ignore and skip rules', () async {
    net.add('alice');
    net.add('bob');
    writeText(at(0, '.syncignore'), '*.log\n');
    writeText(at(0, 'a.log'), 'log');
    writeText(at(0, 'notes.txt'), 'notes');
    writeText(at(0, 'local.txt'), 'shared at first');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'notes.txt')) == 'notes');
    await eventually(() => contents(at(1, '.syncignore')) == '*.log\n');
    await eventually(() => contents(at(1, 'local.txt')) == 'shared at first');
    expect(File(at(1, 'a.log')).existsSync(), isFalse);

    // Newly ignored: deleted as far as sync goes, but every member ignores it
    // too, so nobody's copy is removed.
    writeText(at(0, '.syncignore'), '*.log\nnotes.txt\n');
    await eventually(() => contents(at(1, '.syncignore')) == '*.log\nnotes.txt\n');
    await wait(800);
    expect(File(at(0, 'notes.txt')).existsSync(), isTrue);
    expect(File(at(1, 'notes.txt')).existsSync(), isTrue);

    // Skipped on bob: his copy goes its own way, and .syncskip stays his.
    writeText(at(1, '.syncskip'), 'local.txt\n');
    await wait(400);
    writeText(at(1, 'local.txt'), 'bob keeps this');
    writeText(at(0, 'local.txt'), 'alice changed it');
    await wait(1500);
    expect(contents(at(0, 'local.txt')), 'alice changed it');
    expect(contents(at(1, 'local.txt')), 'bob keeps this');
    expect(File(at(0, '.syncskip')).existsSync(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // A member joining while already connected (as when accepting an offer).
  test('joins while connected', () async {
    net.add('alice');
    net.add('bob');
    writeText(at(0, 'a.txt'), 'alpha');
    net.join(0);
    net.link(0, 1);
    await wait(500);
    net.join(1);
    await eventually(() => contents(at(1, 'a.txt')) == 'alpha');
    writeText(at(1, 'b.txt'), 'from bob');
    await eventually(() => contents(at(0, 'b.txt')) == 'from bob');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('relays through a member', () async {
    net.add('alice');
    net.add('bob');
    net.add('carol');
    net.join(0);
    net.join(1);
    net.join(2);
    net.link(0, 1);
    net.link(1, 2); // alice and carol never meet
    writeText(at(0, 'hello.txt'), 'from alice');
    await eventually(() => contents(at(2, 'hello.txt')) == 'from alice',
        timeout: const Duration(seconds: 15));
    writeText(at(2, 'reply.txt'), 'from carol');
    await eventually(() => contents(at(0, 'reply.txt')) == 'from carol',
        timeout: const Duration(seconds: 15));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('refuses what would leave the folder', () async {
    net.add('alice');
    net.add('bob');
    final outside = '${net.dir.path}${Platform.pathSeparator}outside';
    writeText('$outside${Platform.pathSeparator}secret.txt', 'secret');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    var linked = false;
    try {
      if (Platform.isWindows) {
        linked = (await Process.run('cmd', ['/c', 'mklink', '/J', at(1, 'escape'), outside]))
                .exitCode ==
            0;
      } else {
        Link(at(1, 'escape')).createSync(outside);
        linked = true;
      }
    } on Object {
      linked = false;
    }
    // A crafted index from bob: paths out of the folder are dropped, and a
    // file whose blocks bob will not serve is never written.
    final fake = FileEntry(
      path: 'escape/planted.txt',
      size: 5,
      hash: Uint8List.fromList(List.filled(32, 0x78)),
      blockSize: 128 * 1024,
      blocks: [Uint8List.fromList(List.filled(32, 0x78))],
      version: {'zz': 1},
    );
    final evil = fake.toJson()..['p'] = '../planted.txt';
    net.nodes[0].svc.handleControl(net.nodes[1].dev, {
      't': 'sync.index',
      'folder': kFolder,
      'epoch': '1',
      'full': false,
      'entries': [evil, fake.toJson()],
    });
    writeText(at(0, 'fine.txt'), 'fine');
    await eventually(() => contents(at(1, 'fine.txt')) == 'fine');
    await wait(800);
    expect(File('${net.dir.path}${Platform.pathSeparator}planted.txt').existsSync(),
        isFalse);
    expect(File('$outside${Platform.pathSeparator}planted.txt').existsSync(), isFalse);
    if (linked) {
      expect(File(at(0, 'escape/secret.txt')).existsSync(), isFalse); // bob's link is not synced
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
