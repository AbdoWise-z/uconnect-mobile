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
  final offered = <String, int>{}; // peer key -> folders in its last offers
}

class Net {
  Net() : dir = Directory.systemTemp.createTempSync('uconnect_sync');

  final Directory dir;
  final nodes = <Node>[];
  final links = <String>{};
  final since = <String, int>{};
  final inFlight = <String, int>{};
  final noOffersTo = <String>{}; // "from>to": `from` does not offer folders to `to`
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
      offersTo: (d) => !noOffersTo.contains('$index>${indexOf(d)}'),
    )
      ..scanIntervalMs = 150
      ..stableAfterMs = 0;
    n.svc.folderChanged.listen((id) => n.status = n.svc.folderStatus(id));
    n.svc.offers.listen((o) => n.offered[o.peerKey] = o.folders.length);
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

// path -> state, as the user would see it.
Map<String, String> statesOf(Node n) =>
    {for (final r in n.svc.files(kFolder)) '${r['path']}': '${r['state']}'};

Map<String, Object?> rowOf(Node n, String path) =>
    n.svc.files(kFolder).where((r) => r['path'] == path).firstOrNull ?? const {};

Map<String, Object?> memberOf(Node n, String key) {
  for (final m in (n.status['members'] as List?) ?? const []) {
    if (m is Map && m['key'] == key) return m.cast<String, Object?>();
  }
  return const {};
}

int intOf(Map<String, Object?> m, String key) => (m[key] as num?)?.toInt() ?? 0;

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

  // --- what the user sees ---------------------------------------------------------------

  test('lists files with their state', () async {
    net.add('alice');
    net.add('bob');
    final a = net.nodes[0], b = net.nodes[1];
    writeText(at(0, 'a.txt'), 'alpha');
    writeText(at(0, 'sub/b.txt'), 'bravo');
    writeText(at(0, 'x.log'), 'log');
    writeText(at(0, 'mine.txt'), 'mine');
    writeText(at(0, '.syncignore'), '*.log\n');
    writeText(at(0, '.syncskip'), 'mine.txt\n');
    net.join(0);
    net.join(1);
    // Alone: everything of hers is still to be sent to bob.
    await eventually(() => statesOf(a).containsKey('sub/b.txt'));
    var states = statesOf(a);
    expect(states['a.txt'], 'send');
    expect(states['sub/b.txt'], 'send');
    expect(states['sub'], 'send');
    expect(states['x.log'], 'ignored');
    expect(rowOf(a, 'x.log')['detail'], '*.log');
    expect(states['mine.txt'], 'skipped');
    expect(rowOf(a, 'mine.txt')['detail'], 'mine.txt');
    expect(rowOf(a, 'sub')['dir'], isTrue);
    expect(rowOf(a, 'a.txt')['size'], 5);
    await eventually(() => intOf(memberOf(a, b.key), 'toSendFiles') == 3);
    expect(memberOf(a, b.key)['online'], isFalse);

    net.link(0, 1);
    await eventually(() => contents(at(1, 'sub/b.txt')) == 'bravo');
    await eventually(() => statesOf(a)['sub/b.txt'] == 'synced');
    states = statesOf(a);
    expect(states['a.txt'], 'synced');
    expect(states['.syncignore'], 'synced');
    expect(states['x.log'], 'ignored');
    expect(states['mine.txt'], 'skipped');
    expect(states.containsKey('.syncskip'), isFalse);
    states = statesOf(b);
    expect(states['a.txt'], 'synced');
    expect(states.containsKey('x.log'), isFalse); // never came, and is not here
    expect(states.containsKey('mine.txt'), isFalse);
    await eventually(() => intOf(memberOf(a, b.key), 'toSendFiles') == 0);
    expect(memberOf(a, b.key)['online'], isTrue);
    await eventually(() => intOf(memberOf(a, b.key), 'lastInSync') > 0);
    // Skipped before it ever synced, mine.txt is in nobody's index.
    expect(intOf(memberOf(b, a.key), 'skipped'), 0);

    // A path in depth.
    final info = b.svc.fileInfo(kFolder, 'a.txt');
    expect(info['state'], 'synced');
    expect((info['holders'] as List).length, 1);
    expect((info['version'] as Map).length, 1);

    // Bob's copy of the index outlives the connection: what he has yet to
    // fetch waits for alice to come back.
    net.unlink(0, 1);
    writeText(at(0, 'late.txt'), 'late');
    await eventually(() => statesOf(a)['late.txt'] == 'send');
    await eventually(() => intOf(memberOf(a, b.key), 'toSendFiles') == 1);
    final c = net.config(1);
    b.svc.setFolders([
      FolderConfig(id: c.id, label: c.label, path: c.path, paused: true, peers: c.peers)
    ]); // takes the index, fetches nothing
    net.link(0, 1);
    await eventually(
        () => (b.svc.fileInfo(kFolder, 'late.txt')['holders'] as List? ?? []).isNotEmpty);
    net.unlink(0, 1);
    net.join(1);
    await eventually(() => statesOf(b)['late.txt'] == 'receive');
    expect(rowOf(b, 'late.txt')['detail'], 'waiting');
    await eventually(() => intOf(memberOf(b, a.key), 'toReceiveFiles') == 1);
    expect(File(at(1, 'late.txt')).existsSync(), isFalse);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'late.txt')) == 'late');
    await eventually(() => statesOf(b)['late.txt'] == 'synced');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('holds back large deletes', () async {
    net.add('alice');
    net.add('bob');
    final a = net.nodes[0], b = net.nodes[1];
    for (var i = 0; i < 12; i++) {
      writeText(at(0, 'f$i.txt'), 'file');
    }
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'f11.txt')) == 'file', timeout: const Duration(seconds: 20));
    await eventually(() => intOf(b.status, 'files') == 12);

    // Alice wipes most of her copy: bob keeps his files and asks.
    for (var i = 0; i < 11; i++) {
      File(at(0, 'f$i.txt')).deleteSync();
    }
    await eventually(() => intOf(b.status, 'pendingDeleteCount') == 11);
    await eventually(() => b.events.join(';').contains(' deletes:11'));
    await wait(500);
    expect(contents(at(1, 'f0.txt')), 'file');
    expect((b.status['pendingDeletes'] as List).length, 11);

    // Keeping them makes them bob's changes: alice gets them back.
    b.svc.confirmDeletes(kFolder, false);
    await eventually(() => contents(at(0, 'f0.txt')) == 'file', timeout: const Duration(seconds: 20));
    await eventually(() => contents(at(0, 'f10.txt')) == 'file', timeout: const Duration(seconds: 20));
    await eventually(() => intOf(b.status, 'pendingDeleteCount') == 0);
    expect(intOf(b.status, 'files'), 12);

    // Deleting them again, and this time letting it happen.
    await eventually(() => intOf(a.status, 'files') == 12);
    await wait(300);
    for (var i = 0; i < 11; i++) {
      File(at(0, 'f$i.txt')).deleteSync();
    }
    await eventually(() => intOf(b.status, 'pendingDeleteCount') == 11);
    b.svc.confirmDeletes(kFolder, true);
    await eventually(() => !File(at(1, 'f0.txt')).existsSync());
    await eventually(() => intOf(b.status, 'files') == 1);
    expect(contents(at(1, 'f11.txt')), 'file');
    expect(intOf(b.status, 'pendingDeleteCount'), 0);

    // A few deletes in a big folder pass without asking.
    for (var i = 0; i < 40; i++) {
      writeText(at(0, 'g$i.txt'), 'more');
    }
    await eventually(() => intOf(b.status, 'files') == 41, timeout: const Duration(seconds: 20));
    await wait(300);
    for (var i = 0; i < 5; i++) {
      File(at(0, 'g$i.txt')).deleteSync();
    }
    await eventually(() => intOf(b.status, 'files') == 36);
    expect(intOf(b.status, 'pendingDeleteCount'), 0);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('keeps and restores kept files', () async {
    net.add('alice');
    net.add('bob');
    final b = net.nodes[1];
    writeText(at(0, 'docs/x.txt'), 'first');
    writeText(at(0, 'y.txt'), 'why');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'docs/x.txt')) == 'first');
    await eventually(() => contents(at(1, 'y.txt')) == 'why');
    await wait(300);
    File(at(0, 'docs/x.txt')).deleteSync();
    await eventually(() => !File(at(1, 'docs/x.txt')).existsSync());

    await eventually(() => b.svc.keptFiles(kFolder).length == 1);
    final kept = b.svc.keptFiles(kFolder).first;
    expect(kept['path'], 'docs/x.txt');
    expect(kept['size'], 5);
    expect('${kept['kept']}'.startsWith('docs/x~'), isTrue);
    expect(intOf(kept, 'time') > 0, isTrue);
    expect((b.svc.fileInfo(kFolder, 'docs/x.txt')['kept'] as List).length, 1);

    // Restored, it is bob's change: alice gets it back.
    expect(b.svc.restoreKept(kFolder, '${kept['kept']}'), isTrue);
    expect(contents(at(1, 'docs/x.txt')), 'first');
    await eventually(() => contents(at(0, 'docs/x.txt')) == 'first', timeout: const Duration(seconds: 20));
    expect(b.svc.keptFiles(kFolder).length, 0);
    expect(b.svc.restoreKept(kFolder, '../y.txt'), isFalse); // never out of .synctrash
    expect(contents(at(1, 'y.txt')), 'why');

    // Discarding one.
    await wait(300);
    File(at(0, 'y.txt')).deleteSync();
    await eventually(() => b.svc.keptFiles(kFolder).length == 1);
    expect(b.svc.discardKept(kFolder, '${b.svc.keptFiles(kFolder).first['kept']}'), isTrue);
    expect(b.svc.keptFiles(kFolder).length, 0);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('previews and saves rules', () async {
    net.add('alice');
    net.add('bob');
    final a = net.nodes[0], b = net.nodes[1];
    writeText(at(0, 'a.txt'), 'a');
    writeText(at(0, 'b.log'), 'b');
    writeText(at(0, 'docs/c.txt'), 'c');
    writeText(at(0, 'docs/d.log'), 'd');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'docs/d.log')) == 'd');

    final preview = a.svc.previewRules(kFolder, false, '*.log\n!\n/docs/\n', probe: 'docs/new.txt');
    expect((preview['problems'] as List).length, 1);
    expect(((preview['problems'] as List).first as Map)['line'], 2);
    expect(preview['stop'], 3); // b.log, docs/c.txt, docs/d.log
    expect(preview['resume'], 0);
    final matches = {
      for (final m in (preview['matches'] as List).cast<Map>()) '${m['path']}': m
    };
    expect(matches['b.log']!['line'], 1);
    expect(matches['docs']!['line'], 3);
    expect(matches['docs/c.txt']!['via'], 'docs');
    expect(matches.containsKey('a.txt'), isFalse);
    final probe = preview['probe'] as Map;
    expect(probe['line'], 3);
    expect(probe['excluded'], isTrue);

    expect(a.svc.saveRules(kFolder, false, '*.log\n'), isTrue);
    expect(a.svc.rulesText(kFolder, false), '*.log\n');
    await eventually(() => contents(at(1, '.syncignore')) == '*.log\n');
    await eventually(() => statesOf(a)['b.log'] == 'ignored');
    await eventually(() => statesOf(b)['docs/d.log'] == 'ignored');
    expect(File(at(1, 'docs/d.log')).existsSync(), isTrue); // ignoring never deletes
    // Left out now, it would come back without the rule.
    expect(a.svc.previewRules(kFolder, false, '')['resume'], 2);

    // "Skip on this device" for one file.
    expect(b.svc.addRule(kFolder, true, 'docs/c.txt'), isTrue);
    expect(b.svc.rulesText(kFolder, true), '/docs/c.txt\n');
    await eventually(() => statesOf(b)['docs/c.txt'] == 'skipped');
    expect(rowOf(b, 'docs/c.txt')['detail'], '/docs/c.txt');
    await wait(600);
    expect(File(at(0, '.syncskip')).existsSync(), isFalse);
    expect(statesOf(a)['docs/c.txt'], 'synced');
    // Alice sees that bob holds one path back.
    await eventually(() => intOf(memberOf(a, b.key), 'skipped') == 1);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('pauses one device', () async {
    net.add('alice');
    net.add('bob');
    final a = net.nodes[0], b = net.nodes[1];
    writeText(at(0, 'a.txt'), 'a');
    net.join(0);
    net.join(1);
    net.link(0, 1);
    await eventually(() => contents(at(1, 'a.txt')) == 'a');

    FolderConfig withPause(bool paused) {
      final c = net.config(0);
      return FolderConfig(id: c.id, label: c.label, path: c.path, peers: {
        b.key: Grant(receive: true, contribute: true, paused: paused),
      });
    }

    a.svc.setFolders([withPause(true)]);
    await eventually(() => memberOf(a, b.key)['paused'] == true);
    // Bob, no longer offered the folder, forgets alice's index of it.
    await eventually(
        () => (b.svc.fileInfo(kFolder, 'a.txt')['holders'] as List? ?? [1]).isEmpty);
    writeText(at(0, 'b.txt'), 'b');
    writeText(at(1, 'c.txt'), 'c');
    await eventually(() => statesOf(a)['b.txt'] == 'synced'); // nobody to send to
    await wait(1500);
    expect(File(at(1, 'b.txt')).existsSync(), isFalse);
    expect(File(at(0, 'c.txt')).existsSync(), isFalse);

    a.svc.setFolders([withPause(false)]);
    await eventually(() => contents(at(1, 'b.txt')) == 'b');
    await eventually(() => contents(at(0, 'c.txt')) == 'c');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('lists transfers', () async {
    net.add('alice');
    net.add('bob');
    final a = net.nodes[0], b = net.nodes[1];
    final big = randomBytes(6 * 1024 * 1024, 3);
    write(at(0, 'big.bin'), big);
    net.join(0);
    net.join(1);
    net.link(0, 1);
    var seen = false;
    for (var i = 0; i < 400 && !seen; i++) {
      await wait(10);
      for (final t in b.svc.transfers()) {
        if (t['path'] != 'big.bin' || t['active'] != true) continue;
        seen = true;
        expect(t['folder'], kFolder);
        expect(t['size'], big.length);
        expect(t['key'], a.key);
        expect(intOf(t, 'done') <= big.length, isTrue);
      }
    }
    expect(seen, isTrue);
    await eventually(() => bytesOf(at(1, 'big.bin')).length == big.length,
        timeout: const Duration(seconds: 30));
    await eventually(() => b.svc.transfers().isEmpty);
    expect(intOf(memberOf(b, a.key), 'rate') >= 0, isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('waits while suspended', () async {
    net.add('alice');
    net.add('bob');
    final b = net.nodes[1];
    writeText(at(0, 'a.txt'), 'a');
    net.join(0);
    net.join(1);
    b.svc.suspended = 'wifi';
    net.link(0, 1);
    await eventually(() => b.status['state'] == 'waiting');
    expect(b.status['reason'], 'wifi');
    await wait(1500);
    expect(File(at(1, 'a.txt')).existsSync(), isFalse);
    b.svc.suspended = '';
    await eventually(() => contents(at(1, 'a.txt')) == 'a');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('offers follow the Offer sync permission', () async {
    net.add('alice');
    final bob = net.add('bob');
    net.join(0); // alice shares; bob has not joined
    net.noOffersTo.add('0>1');
    net.link(0, 1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(bob.offered[net.nodes[0].key] ?? 0, 0, reason: 'not offered without the permission');
    // Granted: alice tells bob about her folder on the next peerUp.
    net.noOffersTo.remove('0>1');
    net.nodes[0].svc.peerUp(bob.dev);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(bob.offered[net.nodes[0].key], 1);
    // Taken away again: the offers it gets are empty, so it forgets them.
    net.noOffersTo.add('0>1');
    net.nodes[0].svc.peerUp(bob.dev);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(bob.offered[net.nodes[0].key], 0);
  });
}
