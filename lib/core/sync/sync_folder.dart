// One synced folder on this device: its index (what this device has), the
// indexes its peers sent, and the rules that decide, path by path, what to do.
// No network or disk writes happen here (bar its own state file);
// SyncService carries out decisions. A port of uconnect-desktop's SyncFolder.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'sync_ignore.dart';
import 'sync_model.dart';
import 'sync_scanner.dart';

/// What this device allows one peer, for one folder.
class Grant {
  const Grant({this.receive = false, this.contribute = false, this.paused = false});
  final bool receive; // send it this folder and our changes
  final bool contribute; // accept its changes
  final bool paused; // neither, for now; the grants are kept

  bool get sends => receive && !paused;
  bool get accepts => contribute && !paused;

  @override
  bool operator ==(Object other) =>
      other is Grant &&
      other.receive == receive &&
      other.contribute == contribute &&
      other.paused == paused;
  @override
  int get hashCode => Object.hash(receive, contribute, paused);
}

/// What is remembered about each member, ms since epoch: when it was last
/// connected, when this device last had nothing to send it or take from it,
/// and how far our index reached it.
class PeerStats {
  PeerStats({this.lastSeen = 0, this.lastInSync = 0, this.sentSeq = 0});
  int lastSeen;
  int lastInSync;
  int sentSeq;
}

class FolderConfig {
  FolderConfig({
    required this.id,
    this.label = '',
    required this.path,
    this.paused = false,
    Map<String, Grant>? peers,
  }) : peers = peers ?? {};

  final String id; // 32 hex, the same on every member
  final String label;
  final String path; // where it is on this device
  final bool paused;
  final Map<String, Grant> peers; // by identity key (hex)

  Grant grantOf(String key) => peers[key] ?? const Grant();
}

/// One of the versions competing in a conflict.
class Candidate {
  Candidate(this.key, this.entry);
  final String key; // identity key of a device holding it; empty for this device
  final FileEntry entry;
}

enum DecisionKind {
  none, // nothing to do
  adopt, // same content as we have, newer version: take the version only
  apply, // bring the disk to `target` (fetch, create a folder or delete)
  conflict, // versions that neither saw; see the fields below
}

class Decision {
  DecisionKind kind = DecisionKind.none;
  FileEntry target = FileEntry();
  List<String> sources = []; // keys of peers holding the content of `target`

  // Conflict
  bool involved = false; // this device's own change is one of them
  String following = ''; // the chain kept: a peer's key, or empty for ours
  bool waiting = false; // behind every candidate, and none of their holders is online
  bool apply = false; // following a peer: `target` and `sources` say what to fetch
  List<Candidate> candidates = [];
}

class Remote {
  String epoch = '0'; // their index's epoch, unsigned 64-bit, as decimal
  int seen = 0; // highest seq of theirs we have
  final entries = <String, FileEntry>{};
}

/// An epoch from the wire, as the canonical decimal of an unsigned 64-bit
/// number ("0" for anything else, as the desktop's toULongLong).
String canonicalEpoch(Object? value) {
  final s = value is String ? value : (value is int ? '$value' : '');
  final n = BigInt.tryParse(s);
  if (n == null || n.isNegative || n.bitLength > 64) return '0';
  return n.toString();
}

// Of names that clash ignoring case, the oldest is synced; ties go to the
// lower name. Folders have no time, so their names decide.
bool _olderThan(int aTime, String a, int bTime, String b) =>
    aTime != bTime ? aTime < bTime : a.compareTo(b) < 0;

// `held` plus everything inside a held folder.
void _holdDescendants(Map<String, String> held, Iterable<String> paths) {
  if (held.isEmpty) return;
  for (final p in paths) {
    for (var slash = p.indexOf('/'); slash >= 0; slash = p.indexOf('/', slash + 1)) {
      final parent = held[p.substring(0, slash)];
      if (parent != null) {
        held[p] = parent;
        break;
      }
    }
  }
}

class SyncFolder {
  SyncFolder(this.config, this.me, this.stateFile) {
    // 63 random bits, so it fits an int and reads the same on every member.
    final r = Random.secure();
    epoch = (r.nextInt(1 << 31) << 32) | r.nextInt(1 << 32);
  }

  FolderConfig config;
  final String me; // this device's member id
  final String stateFile;

  int epoch = 0; // changes when this index starts over; peers then ask for all of it
  int seq = 0; // the last change to the index
  final local = <String, FileEntry>{};
  final remotes = <String, Remote>{}; // by identity key
  final peerStats = <String, PeerStats>{}; // by identity key

  String get epochString => '$epoch';

  IgnoreRules ignore = IgnoreRules(); // .syncignore and .syncskip, as last read
  IgnoreRules skip = IgnoreRules();
  // Resolutions waiting for their content: path -> what the entry becomes.
  final forced = <String, FileEntry>{};

  // Paths this device holds back from sync, and why: "clash:<path>" (the
  // name clashes, ignoring case, with that older one, which is synced) or
  // "name:<problem>" (see nameProblem()). Held-back files stay on disk and are
  // marked skipped, so peers neither take nor delete them; they sync again
  // when what held them back goes.
  var scanHeld = <String, String>{}; // found by the last scan
  var clashHeld = <String, String>{}; // clashes with other devices' names

  String heldReason(String path) => scanHeld[path] ?? clashHeld[path] ?? '';

  bool participates(String path, [bool dir = false]) =>
      !ignore.matches(path, dir) && !skip.matches(path, dir);

  void setLocal(FileEntry e) {
    final c = e.copy()..seq = ++seq;
    local[c.path] = c;
  }

  /// Entries changed after `since`, oldest change first.
  List<FileEntry> changedSince(int since) =>
      [for (final e in local.values) if (e.seq > since) e]
        ..sort((a, b) => a.seq.compareTo(b.seq));

  /// Which live names clash with an older one, ignoring case, given what the
  /// decisions of this round would bring (path -> decision).
  Map<String, String> clashes(Map<String, Decision> decisions) {
    final byName = <String, List<(String, int)>>{};
    final paths = {...local.keys, ...decisions.keys};
    final live = <String>[];
    for (final p in paths) {
      final d = decisions[p];
      if (d != null &&
          (d.kind == DecisionKind.apply ||
              (d.kind == DecisionKind.conflict && d.apply))) {
        if (d.target.deleted) continue;
        (byName[foldName(p)] ??= []).add((p, d.target.dir ? 0 : d.target.mtime));
        live.add(p);
        continue;
      }
      final l = local[p];
      if (l == null || l.deleted || scanHeld.containsKey(p)) continue;
      // Skipped for .syncskip takes no part; held back for a clash still competes.
      if (l.skipped && !clashHeld.containsKey(p)) continue;
      (byName[foldName(p)] ??= []).add((p, l.dir ? 0 : l.mtime));
      live.add(p);
    }
    final held = <String, String>{};
    for (final same in byName.values) {
      if (same.length < 2) continue;
      var oldest = same.first;
      for (final l in same) {
        if (_olderThan(l.$2, l.$1, oldest.$2, oldest.$1)) oldest = l;
      }
      for (final l in same) {
        if (l.$1 != oldest.$1) held[l.$1] = 'clash:${oldest.$1}';
      }
    }
    _holdDescendants(held, live);
    return held;
  }

  /// Turns what a scan saw into index changes; entries changed after
  /// `seqAtStart` (by applying a peer's change meanwhile) are left alone.
  /// Returns how many entries changed.
  int applyScan(ScanResult result, int seqAtStart) {
    if (!result.ok) return 0;
    // The rules this scan went by; the caller may hold newer ones.
    final scanIgnore = IgnoreRules(result.ignoreText);
    final scanSkip = IgnoreRules(result.skipText);
    final before = seq;

    // Names here that clash ignoring case (a case-sensitive disk can hold
    // both): the oldest syncs, the rest are held back. Names some member could
    // not hold are held back too.
    scanHeld = {};
    final oldest = <String, FileEntry>{};
    for (final obs in result.items) {
      final key = foldName(obs.path);
      final o = oldest[key];
      if (o == null) {
        oldest[key] = obs;
      } else if (_olderThan(obs.dir ? 0 : obs.mtime, obs.path,
          o.dir ? 0 : o.mtime, o.path)) {
        scanHeld[o.path] = 'clash:${obs.path}';
        oldest[key] = obs;
      } else {
        scanHeld[obs.path] = 'clash:${o.path}';
      }
    }
    // A loser's own clash target may itself have lost to an older name later on.
    for (final k in scanHeld.keys.toList()) {
      scanHeld[k] = 'clash:${oldest[foldName(k)]!.path}';
    }
    _holdDescendants(scanHeld, [for (final obs in result.items) obs.path]);
    result.unsupported.forEach((path, problem) => scanHeld[path] = 'name:$problem');

    void holdBack(String path) {
      final it = local[path];
      if (it != null && !it.deleted && !it.skipped) {
        setLocal(it.copy()..skipped = true); // stays on disk; peers neither take nor delete it
      }
    }

    final seen = <String>{};
    for (final obs in result.items) {
      seen.add(obs.path);
      final it = local[obs.path];
      if (it != null && it.seq > seqAtStart) continue; // we changed it since the scan began
      if (scanHeld.containsKey(obs.path) || clashHeld.containsKey(obs.path)) {
        holdBack(obs.path);
        continue;
      }
      if (it != null &&
          !it.deleted &&
          it.dir == obs.dir &&
          (obs.dir || bytesEqual(it.hash, obs.hash))) {
        if (it.skipped) {
          setLocal(it.copy()..skipped = false); // taking part again, with the same content
        } else if (!obs.dir && (it.mtime != obs.mtime || it.size != obs.size)) {
          it.mtime = obs.mtime; // touched, not changed: nothing to tell anyone
        }
        continue;
      }
      setLocal(obs.copy()..version = bumpedVersion(it?.version ?? {}, me));
    }

    for (final path in local.keys.toList()) {
      final l = local[path]!;
      if (l.deleted ||
          seen.contains(path) ||
          l.seq > seqAtStart ||
          result.unstable.contains(path)) {
        continue;
      }
      if (scanHeld.containsKey(path) || clashHeld.containsKey(path)) {
        holdBack(path);
        continue;
      }
      if (scanSkip.matches(path, l.dir) && !scanIgnore.matches(path, l.dir)) {
        if (!l.skipped) setLocal(l.copy()..skipped = true);
        continue;
      }
      // Gone from disk, or newly ignored (which counts as deleted; the file
      // itself is left alone).
      setLocal(FileEntry(
          path: path, deleted: true, version: bumpedVersion(l.version, me)));
    }
    return seq - before;
  }

  /// A peer's index, or a part of it. `full`: everything it has, so what we
  /// held of it before goes.
  void applyRemote(String key, String remoteEpoch, bool full, List<FileEntry> entries) {
    final r = remotes.putIfAbsent(key, Remote.new);
    if (full || r.epoch != remoteEpoch) {
      r.entries.clear();
      r.seen = 0;
    }
    r.epoch = remoteEpoch;
    for (final e in entries) {
      r.entries[e.path] = e;
      if (e.seq > r.seen) r.seen = e.seq;
    }
  }

  List<Candidate> _candidatesFor(String path) {
    final all = <Candidate>[];
    final l = local[path];
    if (l != null && !l.skipped) all.add(Candidate('', l));
    remotes.forEach((key, r) {
      if (!config.grantOf(key).accepts) return;
      final e = r.entries[path];
      if (e != null && !e.skipped) all.add(Candidate(key, e));
    });
    return all;
  }

  List<String> _holdersOf(FileEntry content) {
    final out = <String>[];
    if (content.deleted || content.dir) return out;
    remotes.forEach((key, r) {
      if (!config.grantOf(key).accepts) return;
      final e = r.entries[content.path];
      if (e != null && !e.skipped && e.sameContent(content)) out.add(key);
    });
    return out;
  }

  /// `connectedSince(key)`: when the connection to that peer began (ms since
  /// epoch), or -1 if it is not connected.
  Decision decide(String path, int Function(String key) connectedSince) {
    final d = Decision();
    final l = local[path];
    var isDir = l != null && l.dir;
    for (final r in remotes.values) {
      if (r.entries[path]?.dir == true) isDir = true;
    }
    if (!participates(path, isDir)) return d;

    // A conflict resolution waiting for its content.
    final f = forced[path];
    if (f != null) {
      d.target = f.copy();
      if (l != null && l.sameContent(f)) {
        d.kind = DecisionKind.adopt;
        d.target = l.copy()..version = Map.of(f.version);
      } else {
        d.kind = DecisionKind.apply;
        d.sources = _holdersOf(f);
      }
      return d;
    }

    final all = _candidatesFor(path);
    if (all.isEmpty) return d;

    // The newest versions: those no other candidate has seen past.
    final maxima = <int>[];
    for (var i = 0; i < all.length; i++) {
      var dominated = false;
      for (var j = 0; j < all.length && !dominated; j++) {
        dominated = i != j &&
            compareVersions(all[i].entry.version, all[j].entry.version) ==
                Order.older;
      }
      if (!dominated) maxima.add(i);
    }
    // Grouped by what they hold: different versions of the same content are
    // no conflict.
    final groups = <List<int>>[];
    for (final i in maxima) {
      final g = groups
          .where((group) => all[group.first].entry.sameContent(all[i].entry))
          .firstOrNull;
      if (g == null) {
        groups.add([i]);
      } else {
        g.add(i);
      }
    }
    VersionVector mergedOf(List<int> group) {
      VersionVector v = {};
      for (final i in group) {
        v = mergedVersions(v, all[i].entry.version);
      }
      return v;
    }

    // Prefer our own entry as the representative: it has our size and time.
    FileEntry representative(List<int> group) {
      for (final i in group) {
        if (all[i].key.isEmpty) return all[i].entry.copy();
      }
      return all[group.first].entry.copy();
    }

    final haveLocal = l != null && !l.skipped;
    if (groups.length == 1) {
      final target = representative(groups.first)..version = mergedOf(groups.first);
      if (haveLocal && l.sameContent(target)) {
        if (versionsEqual(l.version, target.version)) return d;
        d.kind = DecisionKind.adopt;
        d.target = l.copy()..version = target.version;
        return d;
      }
      d.kind = DecisionKind.apply;
      d.target = target;
      d.sources = _holdersOf(target);
      return d;
    }

    // A conflict.
    d.kind = DecisionKind.conflict;
    var localGroup = -1;
    for (var g = 0; g < groups.length; g++) {
      final rep = representative(groups[g])..version = mergedOf(groups[g]);
      var key = '';
      for (final i in groups[g]) {
        if (all[i].key.isEmpty) localGroup = g;
      }
      if (localGroup != g) key = all[groups[g].first].key;
      d.candidates.add(Candidate(key, rep));
    }
    if (localGroup >= 0) {
      // We hold one of them. It is ours if it has a change of ours the others
      // never saw; otherwise we just stay on the chain we are on.
      final mine = l!.version[me] ?? 0;
      d.involved = mine > 0;
      for (var g = 0; g < groups.length; g++) {
        if (g != localGroup && (mergedOf(groups[g])[me] ?? 0) >= mine) {
          d.involved = false;
        }
      }
      return d;
    }
    // Behind all of them: follow the one held by the peer we have been
    // connected to longest.
    var best = -1;
    var bestSince = 0;
    var bestKey = '';
    for (var g = 0; g < groups.length; g++) {
      for (final i in groups[g]) {
        final since = all[i].key.isEmpty ? -1 : connectedSince(all[i].key);
        if (since < 0) continue;
        if (best < 0 || since < bestSince) {
          best = g;
          bestSince = since;
          bestKey = all[i].key;
        }
      }
    }
    if (best < 0) {
      d.waiting = true;
      return d;
    }
    d.following = bestKey;
    d.apply = true;
    d.target = representative(groups[best])..version = mergedOf(groups[best]);
    d.sources = _holdersOf(d.target);
    return d;
  }

  /// Every path any index or resolution names, sorted: folders before what is
  /// in them (deletes are handled deepest first by the caller).
  List<String> allPaths() {
    final paths = <String>{...local.keys, ...forced.keys};
    for (final r in remotes.values) {
      paths.addAll(r.entries.keys);
    }
    return paths.toList()..sort();
  }

  // Conflict resolutions. Each gives the result a version newer than every
  // candidate, so it settles the conflict on every device it reaches.
  bool keepMine(String path) {
    final l = local[path];
    if (l == null) return false;
    VersionVector v = {};
    for (final c in _candidatesFor(path)) {
      v = mergedVersions(v, c.entry.version);
    }
    forced.remove(path);
    setLocal(l.copy()
      ..skipped = false
      ..version = bumpedVersion(v, me));
    return true;
  }

  bool take(String path, String key) {
    final e = remotes[key]?.entries[path];
    if (e == null) return false;
    VersionVector v = {};
    for (final c in _candidatesFor(path)) {
      v = mergedVersions(v, c.entry.version);
    }
    forced[path] = e.copy()
      ..skipped = false
      ..version = bumpedVersion(v, me);
    return true;
  }

  bool load() {
    final Object? decoded;
    try {
      final f = File(stateFile);
      if (!f.existsSync()) return false;
      decoded = jsonDecode(f.readAsStringSync());
    } on Object {
      return false;
    }
    if (decoded is! Map || decoded.isEmpty) return false;
    epoch = decoded['epoch'] is int ? decoded['epoch'] as int : epoch;
    seq = decoded['seq'] is int ? decoded['seq'] as int : 0;
    local.clear();
    for (final v in (decoded['local'] as List? ?? const [])) {
      if (v is! Map) continue;
      final e = FileEntry.fromStorage(v.cast<String, Object?>());
      local[e.path] = e;
    }
    remotes.clear();
    final rs = decoded['remotes'];
    if (rs is Map) {
      rs.forEach((key, rm) {
        if (rm is! Map) return;
        final r = Remote()
          ..epoch = canonicalEpoch(rm['epoch'])
          ..seen = rm['seen'] is int ? rm['seen'] as int : 0;
        for (final v in (rm['entries'] as List? ?? const [])) {
          if (v is! Map) continue;
          final e = FileEntry.fromStorage(v.cast<String, Object?>());
          r.entries[e.path] = e;
        }
        remotes[key.toString()] = r;
      });
    }
    forced.clear();
    final fs = decoded['forced'];
    if (fs is Map) {
      fs.forEach((path, e) {
        if (e is Map) forced[path.toString()] = FileEntry.fromStorage(e.cast<String, Object?>());
      });
    }
    peerStats.clear();
    final ps = decoded['peers'];
    if (ps is Map) {
      ps.forEach((key, v) {
        if (v is! Map) return;
        peerStats[key.toString()] = PeerStats(
            lastSeen: v['lastSeen'] is int ? v['lastSeen'] as int : 0,
            lastInSync: v['lastInSync'] is int ? v['lastInSync'] as int : 0,
            sentSeq: v['sentSeq'] is int ? v['sentSeq'] as int : 0);
      });
    }
    return true;
  }

  bool save() {
    final m = {
      'epoch': epoch,
      'seq': seq,
      'local': [for (final e in local.values) e.toStorage()],
      'remotes': {
        for (final r in remotes.entries)
          r.key: {
            'epoch': r.value.epoch,
            'seen': r.value.seen,
            'entries': [for (final e in r.value.entries.values) e.toStorage()],
          }
      },
      'forced': {for (final f in forced.entries) f.key: f.value.toStorage()},
      'peers': {
        for (final p in peerStats.entries)
          p.key: {
            'lastSeen': p.value.lastSeen,
            'lastInSync': p.value.lastInSync,
            'sentSeq': p.value.sentSeq,
          }
      },
    };
    try {
      final tmp = File('$stateFile.tmp');
      tmp.parent.createSync(recursive: true);
      tmp.writeAsStringSync(jsonEncode(m), flush: true);
      tmp.renameSync(stateFile);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  void removeState() {
    try {
      File(stateFile).deleteSync();
    } on FileSystemException {
      // nothing saved
    }
  }
}
