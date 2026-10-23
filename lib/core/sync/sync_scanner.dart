// Reads a synced folder as it is on disk. A port of uconnect-desktop's
// SyncScanner. scanFolder() touches nothing but the folder and what it is
// given, so scanFolderInBackground() runs it in another isolate, keeping the
// hashing off the UI isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sync_ignore.dart';
import 'sync_model.dart';

class ScanInput {
  ScanInput(this.root, this.known, {this.stableAfterMs = 2000});

  final String root; // real path of the synced folder
  // What the index says, so unchanged files (same size and time) are not
  // read again.
  final Map<String, FileEntry> known;
  // Files changed more recently than this are still being written; they are
  // left for a later scan.
  final int stableAfterMs;
}

class ScanResult {
  bool ok = true; // false: the folder itself is missing or unreadable
  String ignoreText = ''; // .syncignore and .syncskip as read for this scan
  String skipText = '';
  final items = <FileEntry>[]; // everything present and taking part; no versions yet
  final unstable = <String>{}; // present but still changing
  // Present but named so that some member could not hold it: path ->
  // nameProblem(). Not synced; the user is told.
  final unsupported = <String, String>{};
}

String readSmallFile(String path) {
  try {
    final f = File(path).openSync();
    try {
      return utf8.decode(f.readSync(1024 * 1024), allowMalformed: true);
    } finally {
      f.closeSync();
    }
  } on FileSystemException {
    return '';
  }
}

String joinPath(String root, String rel) =>
    rel.isEmpty ? root : '$root${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';

String baseName(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i < 0 ? path : path.substring(i + 1);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Hashes one file into blocks; false if it cannot be read or changed
/// meanwhile.
bool hashFile(String path, FileEntry e) {
  RandomAccessFile file;
  FileStat before;
  try {
    before = FileStat.statSync(path);
    file = File(path).openSync();
  } on FileSystemException {
    return false;
  }
  try {
    e.size = file.lengthSync();
    e.blockSize = blockSizeFor(e.size);
    e.blocks = [];
    final out = _DigestSink();
    final whole = sha256.startChunkedConversion(out);
    while (true) {
      final block = file.readSync(e.blockSize);
      if (block.isEmpty) break;
      whole.add(block);
      e.blocks.add(Uint8List.fromList(sha256.convert(block).bytes));
    }
    whole.close();
    e.hash = Uint8List.fromList(out.value!.bytes);
  } on FileSystemException {
    return false;
  } finally {
    file.closeSync();
  }
  // Written to while being read: the hashes describe no single version.
  final after = FileStat.statSync(path);
  return after.size == e.size && after.modified == before.modified;
}

class _Walker {
  _Walker(this.input, this.ignore, this.skip, this.out);

  final ScanInput input;
  final IgnoreRules ignore;
  final IgnoreRules skip;
  final ScanResult out;
  final int now = DateTime.now().millisecondsSinceEpoch;

  void walk(String dirPath, String relDir) {
    List<FileSystemEntity> children;
    try {
      children = Directory(dirPath).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    children.sort((a, b) => baseName(a.path).compareTo(baseName(b.path)));
    for (final fe in children) {
      // macOS hands names out in another Unicode form and finds files by
      // either; the index keeps the form every other system uses.
      final raw = baseName(fe.path);
      final name = Platform.isMacOS ? nfc(raw) : raw;
      final rel = relDir.isEmpty ? name : '$relDir/$name';
      // Links are not synced: following one could lead out of the folder.
      if (fe is Link || FileSystemEntity.isLinkSync(fe.path)) continue;
      if (name.startsWith(kPartPrefix)) continue;
      if (relDir.isEmpty && (name == kSkipFile || name == kKeptDir)) continue;
      final dir = fe is Directory;
      if (ignore.matches(rel, dir) || skip.matches(rel, dir)) continue;
      final problem = nameProblem(name);
      if (problem.isNotEmpty) {
        out.unsupported[rel] = problem; // and nothing inside it, if a folder
        continue;
      }
      if (!isValidSyncPath(rel)) continue;

      final e = FileEntry(path: rel, dir: dir);
      if (dir) {
        out.items.add(e);
        walk(fe.path, rel);
        continue;
      }
      final FileStat st;
      try {
        st = fe.statSync();
      } on FileSystemException {
        out.unstable.add(rel);
        continue;
      }
      e.size = st.size;
      e.mtime = st.modified.millisecondsSinceEpoch;
      final age = now - e.mtime; // a time in the future is not "still changing"
      if (age >= 0 && age < input.stableAfterMs) {
        out.unstable.add(rel);
        continue;
      }
      final known = input.known[rel];
      if (known != null &&
          !known.deleted &&
          !known.dir &&
          known.size == e.size &&
          known.mtime == e.mtime &&
          known.hash.length == 32) {
        e.hash = known.hash;
        e.blockSize = known.blockSize;
        e.blocks = List.of(known.blocks);
      } else if (!hashFile(fe.path, e)) {
        out.unstable.add(rel); // changed while being read, or unreadable for now
        continue;
      }
      out.items.add(e);
    }
  }
}

ScanResult scanFolder(ScanInput input) {
  final out = ScanResult();
  if (!Directory(input.root).existsSync()) {
    out.ok = false;
    return out;
  }
  out.ignoreText = readSmallFile(joinPath(input.root, kIgnoreFile));
  out.skipText = readSmallFile(joinPath(input.root, kSkipFile));
  _Walker(input, IgnoreRules(out.ignoreText), IgnoreRules(out.skipText), out)
      .walk(input.root, '');
  return out;
}

/// scanFolder() in another isolate.
Future<ScanResult> scanFolderInBackground(ScanInput input) =>
    Isolate.run(() => scanFolder(input));
