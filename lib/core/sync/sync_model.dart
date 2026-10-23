// The data the sync service keeps and exchanges: one entry per file or folder
// in a synced folder, versioned with a version vector so devices can tell,
// without a central node or clocks, which of two versions is newer or that
// they conflict. A port of uconnect-desktop's src/core/sync/SyncModel; see its
// docs/protocol.md, "Folder sync".

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// member id -> how many changes that member has made to this file.
typedef VersionVector = Map<String, int>;

enum Order {
  equal,
  newer, // the first has seen everything the second has, and more
  older,
  concurrent, // each has a change the other has not seen: a conflict
}

Order compareVersions(VersionVector a, VersionVector b) {
  var aAhead = false, bAhead = false;
  a.forEach((k, v) {
    final other = b[k] ?? 0;
    if (v > other) {
      aAhead = true;
    } else if (v < other) {
      bAhead = true;
    }
  });
  b.forEach((k, v) {
    if (!a.containsKey(k) && v > 0) bAhead = true;
  });
  if (aAhead && bAhead) return Order.concurrent;
  if (aAhead) return Order.newer;
  if (bAhead) return Order.older;
  return Order.equal;
}

/// The highest counter of each member.
VersionVector mergedVersions(VersionVector a, VersionVector b) {
  final out = Map<String, int>.of(a);
  b.forEach((k, v) {
    if (v > (out[k] ?? 0)) out[k] = v;
  });
  return out;
}

/// `v` with `member`'s counter raised by one: a new version that follows `v`.
VersionVector bumpedVersion(VersionVector v, String member) =>
    Map<String, int>.of(v)..[member] = (v[member] ?? 0) + 1;

/// The same keys with the same counters (as QMap equality).
bool versionsEqual(VersionVector a, VersionVector b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}

String bytesToHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Strict hex decoding; an empty list for anything that is not hex.
Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) return Uint8List(0);
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(hex.substring(2 * i, 2 * i + 2), radix: 16);
    if (v == null) return Uint8List(0);
    out[i] = v;
  }
  return out;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List sha256Of(List<int> data) =>
    Uint8List.fromList(sha256.convert(data).bytes);

/// A member's id in version vectors: the first 16 hex digits of the SHA-256 of
/// its identity key, so it stays the same whatever the device's session id.
String memberIdOf(String identityKeyHex) =>
    sha256.convert(hexToBytes(identityKeyHex)).toString().substring(0, 16);

int? _integer(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt();
  return null;
}

class FileEntry {
  FileEntry({
    this.path = '',
    this.dir = false,
    this.deleted = false,
    this.skipped = false,
    this.size = 0,
    this.mtime = 0,
    Uint8List? hash,
    this.blockSize = 0,
    List<Uint8List>? blocks,
    VersionVector? version,
    this.seq = 0,
  })  : hash = hash ?? Uint8List(0),
        blocks = blocks ?? <Uint8List>[],
        version = version ?? <String, int>{};

  String path; // relative, '/'-separated
  bool dir;
  bool deleted;
  // The device no longer takes part in this path (.syncskip); others leave
  // it out when choosing a version.
  bool skipped;
  int size;
  int mtime; // ms since epoch
  Uint8List hash; // SHA-256 of the whole file, raw
  int blockSize;
  List<Uint8List> blocks; // SHA-256 of each block, raw
  VersionVector version;
  int seq; // when it last changed in the index that holds it

  /// A copy whose version map is its own (hashes are never changed in place).
  FileEntry copy() => FileEntry(
        path: path,
        dir: dir,
        deleted: deleted,
        skipped: skipped,
        size: size,
        mtime: mtime,
        hash: hash,
        blockSize: blockSize,
        blocks: List.of(blocks),
        version: Map.of(version),
        seq: seq,
      );

  /// Same thing on disk: both deleted, both the same folder, or files with
  /// the same contents.
  bool sameContent(FileEntry other) {
    if (deleted || other.deleted) return deleted == other.deleted;
    if (dir || other.dir) return dir == other.dir;
    return size == other.size && bytesEqual(hash, other.hash);
  }

  int blockLength(int index) {
    final start = index * blockSize;
    final rest = size - start;
    return rest < blockSize ? rest : blockSize;
  }

  Map<String, Object?> toJson() {
    final o = <String, Object?>{
      'p': path,
      'v': Map<String, int>.of(version),
      'q': seq,
    };
    if (skipped) o['skip'] = true;
    if (deleted) {
      o['del'] = true;
      return o;
    }
    if (dir) {
      o['dir'] = true;
      return o;
    }
    o['s'] = size;
    o['m'] = mtime;
    o['h'] = bytesToHex(hash);
    o['bs'] = blockSize;
    o['b'] = [for (final h in blocks) bytesToHex(h)];
    return o;
  }

  /// A peer's entry, or null if it cannot be relied on.
  static FileEntry? fromJson(Map<String, Object?> o) {
    final e = FileEntry(
      path: o['p'] is String ? o['p'] as String : '',
      deleted: o['del'] == true,
      dir: o['dir'] == true,
      skipped: o['skip'] == true,
    );
    final q = _integer(o['q']) ?? 0;
    e.seq = q < 0 ? 0 : q;
    final v = o['v'];
    if (v is Map) {
      for (final entry in v.entries) {
        final key = entry.key.toString();
        final n = _integer(entry.value) ?? -1;
        if (n < 0 || key.isEmpty || key.length > 64) return null;
        e.version[key] = n;
      }
    }
    if (!isValidSyncPath(e.path) ||
        e.version.isEmpty ||
        e.version.length > 1000) {
      return null;
    }
    if (e.deleted || e.dir) return e;

    e.size = _integer(o['s']) ?? -1;
    e.mtime = _integer(o['m']) ?? 0;
    e.hash = o['h'] is String ? hexToBytes(o['h'] as String) : Uint8List(0);
    e.blockSize = _integer(o['bs']) ?? 0;
    final b = o['b'];
    if (b is List) {
      for (final h in b) {
        e.blocks.add(h is String ? hexToBytes(h) : Uint8List(0));
      }
    }
    // Everything a receiver will rely on when fetching: sizes and hashes that
    // agree.
    final expected = e.size > 0 && e.blockSize > 0
        ? (e.size + e.blockSize - 1) ~/ e.blockSize
        : 0;
    if (e.size < 0 ||
        e.hash.length != 32 ||
        e.blockSize <= 0 ||
        e.blockSize > kMaxBlockSize ||
        e.blocks.length != expected) {
      return null;
    }
    for (final h in e.blocks) {
      if (h.length != 32) return null;
    }
    return e;
  }

  /// This device's own saved form (trusted, so not validated on load).
  Map<String, Object?> toStorage() => {
        'p': path,
        'v': Map<String, int>.of(version),
        'q': seq,
        if (skipped) 'skip': true,
        if (deleted) 'del': true,
        if (dir) 'dir': true,
        if (!deleted && !dir) ...{
          's': size,
          'm': mtime,
          'h': bytesToHex(hash),
          'bs': blockSize,
          'b': [for (final h in blocks) bytesToHex(h)],
        },
      };

  static FileEntry fromStorage(Map<String, Object?> m) {
    final e = FileEntry(
      path: m['p'] is String ? m['p'] as String : '',
      seq: _integer(m['q']) ?? 0,
      skipped: m['skip'] == true,
      deleted: m['del'] == true,
      dir: m['dir'] == true,
      size: _integer(m['s']) ?? 0,
      mtime: _integer(m['m']) ?? 0,
      hash: m['h'] is String ? hexToBytes(m['h'] as String) : Uint8List(0),
      blockSize: _integer(m['bs']) ?? 0,
    );
    final v = m['v'];
    if (v is Map) {
      for (final entry in v.entries) {
        e.version[entry.key.toString()] = _integer(entry.value) ?? 0;
      }
    }
    final b = m['b'];
    if (b is List) {
      for (final h in b) {
        if (h is String) e.blocks.add(hexToBytes(h));
      }
    }
    return e;
  }

  @override
  String toString() => jsonEncode(toJson());
}

const int kMaxBlockSize = 16 * 1024 * 1024;

/// Blocks are 128 KiB, doubled until a file has at most 2000 of them, up to
/// 16 MiB.
int blockSizeFor(int fileSize) {
  var size = 128 * 1024;
  while (size < kMaxBlockSize && fileSize ~/ size > 2000) {
    size *= 2;
  }
  return size;
}

/// Temporary files of downloads in progress.
const String kPartPrefix = '.syncpart-';
const String kIgnoreFile = '.syncignore'; // synced
const String kSkipFile = '.syncskip'; // this device only
/// Where files sync deletes or sets aside wait before going away.
const String kKeptDir = '.synctrash';

/// Whether this device's file system tells names apart by case only
/// (Windows and macOS do not), as for ignore patterns.
final bool pathsIgnoreCase = Platform.isWindows || Platform.isMacOS;

const _reserved = {
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

bool isReservedDeviceName(String name) {
  final dot = name.indexOf('.');
  final base = (dot < 0 ? name : name.substring(0, dot)).trim().toUpperCase();
  return _reserved.contains(base);
}

/// Synced names follow the strictest rules of the systems members may run, so
/// every member can hold every synced file. Empty if `name` (one path
/// component) may be synced; otherwise why not:
///   `char:<c>`  one of \ / : * ? " < > | (Windows)
///   "control"   a control character
///   "trailing"  ends with a dot or a space (Windows drops them)
///   "reserved"  CON, PRN, AUX, NUL, COM1-9, LPT1-9, with or without an extension
///   "long"      more than 255 characters
///   "unicode"   not in Unicode normalization form C (macOS stores another form)
///   "invalid"   empty, "." or ".."
String nameProblem(String name) {
  if (name.isEmpty || name == '.' || name == '..') return 'invalid';
  if (name.length > 255) return 'long';
  const forbidden = '\\/:*?"<>|';
  for (final unit in name.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return 'control';
    final c = String.fromCharCode(unit);
    if (forbidden.contains(c)) return 'char:$c';
  }
  if (name.endsWith('.') || name.endsWith(' ')) return 'trailing';
  if (isReservedDeviceName(name)) return 'reserved';
  if (unorm.nfc(name) != name) return 'unicode';
  return '';
}

/// The form two names that one device or another would treat as the same
/// share: case folded, NFC. "Report.txt" and "report.txt" clash.
String foldName(String path) => unorm.nfc(path).toLowerCase();

String nfc(String s) => unorm.nfc(s);

/// A relative path another device may name: synced names only (above), and
/// none of the names the sync service keeps for itself.
bool isValidSyncPath(String path) {
  if (path.isEmpty ||
      path.length > 4096 ||
      path.startsWith('/') ||
      path.endsWith('/')) {
    return false;
  }
  final parts = path.split('/');
  for (final part in parts) {
    if (nameProblem(part).isNotEmpty || part.startsWith(kPartPrefix)) {
      return false;
    }
  }
  if (parts.first == kKeptDir) return false;
  return parts.first != kSkipFile || parts.length > 1;
}
