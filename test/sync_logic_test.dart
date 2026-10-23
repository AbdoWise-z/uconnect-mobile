// The pure parts of folder sync: version vectors, ignore patterns, names, and
// the decisions a folder makes from its own index and its peers'. A port of
// uconnect-desktop's tests/SyncLogicTest.cpp.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/sync/sync_folder.dart';
import 'package:uconnect_mobile/core/sync/sync_ignore.dart';
import 'package:uconnect_mobile/core/sync/sync_model.dart';
import 'package:uconnect_mobile/core/sync/sync_scanner.dart';

const kBob = 'bbbb'; // identity keys of peers
const kCarol = 'cccc';

FileEntry file(String path, String content, VersionVector v) {
  final bytes = utf8.encode(content);
  final e = FileEntry(path: path, size: bytes.length, hash: sha256Of(bytes));
  e.blockSize = blockSizeFor(e.size);
  e.blocks.add(e.hash);
  e.version = Map.of(v);
  return e;
}

FolderConfig config({Map<String, Grant>? peers}) => FolderConfig(
      id: 'f',
      path: '.',
      peers: peers ??
          {
            kBob: const Grant(receive: true, contribute: true),
            kCarol: const Grant(receive: true, contribute: true),
          },
    );

int neverConnected(String _) => -1;

void main() {
  test('compares version vectors', () {
    expect(compareVersions({'B': 1}, {'B': 1}), Order.equal);
    expect(compareVersions({'A': 1, 'B': 1}, {'B': 1}), Order.newer);
    expect(compareVersions({'B': 1}, {'A': 1, 'B': 1}), Order.older);
    // Carol's offline edit against Bob's newer one.
    expect(compareVersions({'A': 1, 'B': 1, 'C': 1}, {'A': 1, 'B': 2}),
        Order.concurrent);
    expect(compareVersions({}, {'A': 1}), Order.older);
    final keep = bumpedVersion(
        mergedVersions({'A': 1, 'B': 1, 'C': 1}, {'A': 1, 'B': 2}), 'C');
    expect(keep, {'A': 1, 'B': 2, 'C': 2});
    expect(compareVersions(keep, {'A': 1, 'B': 2}), Order.newer);
  });

  test('matches ignore patterns', () {
    final r = IgnoreRules('# comment\n*.tmp\n!keep.tmp\n/build\ndocs/*.pdf\ncache/\n**/logs\n'
        '[ab]?.bin\n');
    expect(r.matches('a.tmp', false), isTrue);
    expect(r.matches('deep/down/a.tmp', false), isTrue);
    expect(r.matches('keep.tmp', false), isFalse);
    expect(r.matches('build', true), isTrue);
    expect(r.matches('build/out/x.o', false), isTrue); // inside an ignored folder
    expect(r.matches('src/build', true), isFalse); // anchored at the top
    expect(r.matches('docs/a.pdf', false), isTrue);
    expect(r.matches('docs/sub/a.pdf', false), isFalse);
    expect(r.matches('x/cache', true), isTrue);
    expect(r.matches('x/cache', false), isFalse); // folders only
    expect(r.matches('a/b/logs/today.txt', false), isTrue);
    expect(r.matches('a1.bin', false) && !r.matches('c1.bin', false), isTrue);
    expect(r.matches('readme.md', false), isFalse);

    const odd = 'dir/[draft] *notes?.txt';
    final exact = IgnoreRules(exactPattern(odd));
    expect(exact.matches(odd, false), isTrue);
    expect(exact.matches('dir/d *notesX.txt', false), isFalse);
    expect(exact.matches('other/dir/[draft] *notes?.txt', false), isFalse);
  });

  test('validates paths and entries', () {
    expect(isValidSyncPath('a/b.txt'), isTrue);
    expect(isValidSyncPath('.syncignore'), isTrue);
    expect(isValidSyncPath('.syncskip'), isFalse);
    expect(isValidSyncPath('../x'), isFalse);
    expect(isValidSyncPath('a/../../x'), isFalse);
    expect(isValidSyncPath('/abs'), isFalse);
    expect(isValidSyncPath('a//b'), isFalse);
    expect(isValidSyncPath('a/.syncpart-x'), isFalse);
    expect(isValidSyncPath('.synctrash/a.txt'), isFalse);
    expect(isValidSyncPath('sub/.synctrash'), isTrue); // reserved at the top only
    expect(
        FileEntry.fromJson({
          'p': '../x',
          'v': {'A': 1},
          'del': true
        }),
        isNull);
    // Block hashes must agree with the size.
    final e = file('a.txt', 'hello', {'A': 1});
    final back = FileEntry.fromJson(jsonDecode(jsonEncode(e.toJson())));
    expect(back, isNotNull);
    expect(back!.sameContent(e) && versionsEqual(back.version, e.version), isTrue);
    final bad = e.toJson()..['s'] = 10000000;
    expect(FileEntry.fromJson(bad), isNull);
    // Versions: not empty, non-negative, short keys.
    expect(FileEntry.fromJson({'p': 'a', 'v': {}, 'del': true}), isNull);
    expect(FileEntry.fromJson({'p': 'a', 'v': {'A': -1}, 'del': true}), isNull);
    expect(
        FileEntry.fromJson({
          'p': 'a',
          'v': {'x' * 65: 1},
          'del': true
        }),
        isNull);
    // A bad block hash.
    final short = e.toJson()..['b'] = ['abcd'];
    expect(FileEntry.fromJson(short), isNull);
  });

  test('uses the strictest names', () {
    expect(nameProblem('report.txt'), '');
    expect(nameProblem('notes: draft.txt'), 'char::');
    expect(nameProblem('what?.txt'), 'char:?');
    expect(nameProblem('back\\slash'), 'char:\\');
    expect(nameProblem('tab\tname'), 'control');
    expect(nameProblem('ends with dot.'), 'trailing');
    expect(nameProblem('ends with space '), 'trailing');
    expect(nameProblem('CON'), 'reserved');
    expect(nameProblem('lpt1.log'), 'reserved');
    expect(nameProblem('a' * 256), 'long');
    expect(nameProblem('café'), 'unicode'); // e + accent
    expect(nameProblem('café'), '');
    expect(foldName('Docs/Report.TXT'), foldName('docs/report.txt'));
    expect(isValidSyncPath('a/what?.txt'), isFalse);
    expect(memberIdOf('00' * 32).length, 16);
    expect(blockSizeFor(0), 128 * 1024);
    expect(blockSizeFor(2000 * 128 * 1024), 128 * 1024);
    expect(blockSizeFor(2001 * 128 * 1024), 256 * 1024);
    expect(blockSizeFor(1 << 40), kMaxBlockSize);
  });

  // On a disk that tells case apart, both can exist: the older one syncs.
  test('holds back newer names that clash', () {
    final f = SyncFolder(config(), 'A', '');
    final scan = ScanResult();
    final older = file('Report.txt', 'first', {})..mtime = 100;
    final newer = file('report.txt', 'second', {})..mtime = 200;
    final docs = FileEntry(path: 'Docs', dir: true);
    final docsLower = FileEntry(path: 'docs', dir: true);
    final inside = file('docs/x.txt', 'x', {});
    scan.items.addAll([newer, older, docs, docsLower, inside]);
    scan.unsupported['bad:name.txt'] = 'char::';
    f.applyScan(scan, f.seq);
    expect(f.scanHeld['report.txt'], 'clash:Report.txt');
    expect(f.scanHeld['docs'], 'clash:Docs'); // folders: by name
    expect(f.scanHeld['docs/x.txt'], 'clash:Docs');
    expect(f.scanHeld['bad:name.txt'], 'name:char::');
    expect(f.local.containsKey('Report.txt') && !f.local.containsKey('report.txt'),
        isTrue);
    expect(f.local.containsKey('docs/x.txt'), isFalse);

    // The older one goes: the other syncs.
    scan.items
      ..clear()
      ..add(newer);
    scan.unsupported.clear();
    f.applyScan(scan, f.seq);
    expect(f.scanHeld, isEmpty);
    expect(f.local['Report.txt']!.deleted, isTrue);
    expect(f.local.containsKey('report.txt') && !f.local['report.txt']!.skipped,
        isTrue);
  });

  // Across devices: a newer name here loses to an older one from a peer.
  test('holds back names that clash with peers', () {
    final f = SyncFolder(config(), 'A', '');
    f.setLocal(file('report.txt', 'mine', {'A': 1})..mtime = 200);
    final theirs = file('Report.txt', 'theirs', {'B': 1})..mtime = 100;
    f.applyRemote(kBob, '1', true, [theirs]);
    final decisions = {'Report.txt': f.decide('Report.txt', neverConnected)};
    expect(decisions['Report.txt']!.kind, DecisionKind.apply);
    var held = f.clashes(decisions);
    expect(held['report.txt'], 'clash:Report.txt');
    expect(held.containsKey('Report.txt'), isFalse);

    // Ours is the older one: theirs waits.
    f.local['report.txt']!.mtime = 50;
    held = f.clashes(decisions);
    expect(held['Report.txt'], 'clash:report.txt');
  });

  test('follows newer versions', () {
    final f = SyncFolder(config(), 'A', '');
    f.setLocal(file('a.txt', 'old', {'B': 1}));
    f.applyRemote(kBob, '1', true, [file('a.txt', 'new', {'B': 2})]);
    var d = f.decide('a.txt', neverConnected);
    expect(d.kind, DecisionKind.apply);
    expect(d.sources, [kBob]);
    expect(d.target.version, {'B': 2});

    f.setLocal(file('a.txt', 'mine', {'A': 1, 'B': 2})); // we are ahead
    expect(f.decide('a.txt', neverConnected).kind, DecisionKind.none);

    // The same content under concurrent versions is no conflict.
    f.applyRemote(kCarol, '1', true, [file('a.txt', 'mine', {'B': 2, 'C': 1})]);
    d = f.decide('a.txt', neverConnected);
    expect(d.kind, DecisionKind.adopt);
    expect(d.target.version, {'A': 1, 'B': 2, 'C': 1});
  });

  test('ignores peers without contribute', () {
    final f = SyncFolder(
        config(peers: {
          kBob: const Grant(receive: true, contribute: false),
          kCarol: const Grant(receive: true, contribute: true),
        }),
        'A',
        '');
    f.setLocal(file('a.txt', 'old', {'A': 1}));
    f.applyRemote(kBob, '1', true, [file('a.txt', 'new', {'A': 1, 'B': 1})]);
    expect(f.decide('a.txt', neverConnected).kind, DecisionKind.none);
  });

  test('tells own conflicts from others', () {
    // Carol edited offline while Bob edited: for Carol, it is her conflict.
    final carol = SyncFolder(config(), 'C', '');
    carol.setLocal(file('plan.md', 'carol', {'A': 1, 'B': 1, 'C': 1}));
    carol.applyRemote(kBob, '1', true, [file('plan.md', 'bob', {'A': 1, 'B': 2})]);
    var d = carol.decide('plan.md', neverConnected);
    expect(d.kind, DecisionKind.conflict);
    expect(d.involved, isTrue);
    expect(d.candidates.length, 2);

    // Alice holds Bob's version and did not edit: she stays on Bob's chain.
    final alice = SyncFolder(config(), 'A', '');
    alice.setLocal(file('plan.md', 'bob', {'A': 1, 'B': 2}));
    alice.applyRemote(
        kCarol, '1', true, [file('plan.md', 'carol', {'A': 1, 'B': 1, 'C': 1})]);
    d = alice.decide('plan.md', neverConnected);
    expect(d.kind, DecisionKind.conflict);
    expect(d.involved, isFalse);
    expect(d.apply, isFalse);
    expect(d.following, '');
  });

  test('follows the longest connection when behind', () {
    final dave = SyncFolder(config(), 'D', '');
    dave.setLocal(file('plan.md', 'old', {'A': 1, 'B': 1}));
    dave.applyRemote(kBob, '1', true, [file('plan.md', 'bob', {'A': 1, 'B': 2})]);
    dave.applyRemote(
        kCarol, '1', true, [file('plan.md', 'carol', {'A': 1, 'B': 1, 'C': 1})]);
    int since(String key) => key == kCarol ? 1000 : 5000;
    final d = dave.decide('plan.md', since);
    expect(d.kind, DecisionKind.conflict);
    expect(d.apply, isTrue);
    expect(d.following, kCarol); // connected since 1000, before Bob
    expect(d.sources, [kCarol]);
    expect(bytesEqual(d.target.hash, file('x', 'carol', {}).hash), isTrue);
    expect(dave.decide('plan.md', neverConnected).waiting, isTrue);
  });

  test('resolves conflicts for everyone', () {
    final carol = SyncFolder(config(), 'C', '');
    carol.setLocal(file('plan.md', 'carol', {'A': 1, 'B': 1, 'C': 1}));
    carol.applyRemote(kBob, '1', true, [file('plan.md', 'bob', {'A': 1, 'B': 2})]);
    expect(carol.keepMine('plan.md'), isTrue);
    expect(carol.local['plan.md']!.version, {'A': 1, 'B': 2, 'C': 2});
    expect(carol.decide('plan.md', neverConnected).kind, DecisionKind.none);

    final carol2 = SyncFolder(config(), 'C', '');
    carol2.setLocal(file('plan.md', 'carol', {'A': 1, 'B': 1, 'C': 1}));
    carol2.applyRemote(kBob, '1', true, [file('plan.md', 'bob', {'A': 1, 'B': 2})]);
    expect(carol2.take('plan.md', kBob), isTrue);
    final d = carol2.decide('plan.md', neverConnected);
    expect(d.kind, DecisionKind.apply);
    expect(d.sources, [kBob]);
    expect(d.target.version, {'A': 1, 'B': 2, 'C': 2});
  });

  test('turns scans into versions', () {
    final f = SyncFolder(config(), 'A', '');
    final scan = ScanResult();
    scan.items.addAll([file('a.txt', 'one', {}), file('b.txt', 'two', {})]);
    f.applyScan(scan, f.seq);
    expect(f.local['a.txt']!.version, {'A': 1});

    // Unchanged: nothing; changed: a new version; gone: a tombstone.
    scan.items
      ..clear()
      ..addAll([file('a.txt', 'one', {}), file('b.txt', 'TWO', {})]);
    expect(f.applyScan(scan, f.seq), 1);
    expect(f.local['b.txt']!.version, {'A': 2});
    scan.items
      ..clear()
      ..add(file('b.txt', 'TWO', {}));
    f.applyScan(scan, f.seq);
    expect(f.local['a.txt']!.deleted, isTrue);
    expect(f.local['a.txt']!.version, {'A': 2});

    // Newly ignored counts as deleted; skipped is marked, not deleted.
    scan.items.clear();
    scan.ignoreText = 'b.txt';
    f.applyScan(scan, f.seq);
    expect(f.local['b.txt']!.deleted, isTrue);
    f.setLocal(file('c.txt', 'three', {'A': 1}));
    scan.ignoreText = '';
    scan.skipText = 'c.txt';
    f.applyScan(scan, f.seq);
    expect(f.local['c.txt']!.skipped && !f.local['c.txt']!.deleted, isTrue);
    // A peer's newer version of a skipped file is not applied.
    f.skip = IgnoreRules('c.txt');
    f.applyRemote(kBob, '1', true, [file('c.txt', 'bob', {'A': 1, 'B': 1})]);
    expect(f.decide('c.txt', neverConnected).kind, DecisionKind.none);
  });

  test('keeps state across restarts', () {
    final dir = Directory.systemTemp.createTempSync('sync_state');
    addTearDown(() => dir.deleteSync(recursive: true));
    final state = '${dir.path}${Platform.pathSeparator}f.json';
    final f = SyncFolder(config(), 'A', state);
    f.setLocal(file('a.txt', 'one', {'A': 1}));
    f.applyRemote(kBob, '7', true, [file('a.txt', 'one', {'A': 1})]);
    expect(f.save(), isTrue);
    final g = SyncFolder(config(), 'A', state);
    expect(g.load(), isTrue);
    expect(g.epoch, f.epoch);
    expect(g.seq, f.seq);
    expect(bytesEqual(g.local['a.txt']!.hash, f.local['a.txt']!.hash), isTrue);
    expect(g.remotes[kBob]!.epoch, '7');
    expect(g.remotes[kBob]!.entries.length, 1);
  });

  test('reads epochs as unsigned 64-bit decimals', () {
    expect(canonicalEpoch('18446744073709551615'), '18446744073709551615');
    expect(canonicalEpoch('18446744073709551616'), '0');
    expect(canonicalEpoch('-1'), '0');
    expect(canonicalEpoch('x'), '0');
    expect(canonicalEpoch('007'), '7');
  });
}
