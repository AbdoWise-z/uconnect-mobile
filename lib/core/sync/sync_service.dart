// Folder sync: folders kept the same on every member, peer to peer, with no
// device in charge. Members exchange indexes (sync_folder.dart), fetch the
// blocks they lack from any member that has them, and resolve conflicts as
// described in uconnect-desktop's docs/protocol.md, "Folder sync". A port of
// the desktop's SyncService, wire compatible with it.
//
// Runs on the UI isolate beside the session; folder scans (the hashing) run in
// another isolate. Block reads and writes are small and synchronous, as on the
// desktop's worker thread, so that each step of the work loop sees one state.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'sync_folder.dart';
import 'sync_ignore.dart';
import 'sync_model.dart';
import 'sync_scanner.dart';

/// The folders a peer offers this device.
class SyncOffers {
  SyncOffers(this.peerKey, this.folders);
  final String peerKey;
  final List<Map<String, String>> folders; // [{id, label}]
}

/// Something the user should hear about, once. `kind`: `conflict` (theirs to
/// resolve), `following:<key>` (behind both sides, followed that peer's
/// chain), `kept` (stayed on our chain), `waiting` (no holder online), or
/// `blocked:<reason>` with reason outside | in_the_way | changed | not_empty |
/// io | clash, or `held:<reason>` (see SyncFolder.heldReason()) for a file
/// present here that is not synced.
class SyncEvent {
  SyncEvent(this.folderId, this.path, this.kind, {DateTime? time})
      : time = time ?? DateTime.now();
  final String folderId;
  final String path;
  final String kind;
  final DateTime time;
  @override
  String toString() => '$path $kind';
}

const _workEvery = Duration(milliseconds: 200);
const _frameSize = 256 * 1024; // largest data frame
const _indexBatch = 256 * 1024; // about this much JSON per index message
const _maxInflight = 16; // block requests per peer
const _maxPulls = 32; // files being fetched per folder
const _pumpBudget = 8 * 1024 * 1024; // bytes sent per turn
const _requestTimeoutMs = 30000;
const _saveEveryMs = 2000;
const _saveWhileFetchingMs = 30000;
const _maxPlanPauseMs = 5000;
const _cleanEveryMs = 3600 * 1000;
const _rateWindowMs = 5000; // rates are averaged over this long
const _emitEveryMs = 400; // progress reaches the UI this often
const _freeEveryMs = 10000; // how often the disk's free space is read
const _maxListed = 5000; // rule-preview matches reported
// A kept file's name: <base>~yyyyMMdd-HHmmss[ (n)][.ext]
final _keptName = RegExp(r'^(.*)~(\d{8}-\d{6})(?: \(\d+\))?(\.[^.]*)?$');

Map<String, Object?> _versionMap(VersionVector v) =>
    {for (final e in v.entries) e.key: e.value};

int _doneOf(FileEntry target, int missing) {
  final done = (target.blocks.length - missing) * target.blockSize;
  return done > target.size ? target.size : done;
}

int? _keptStamp(String stamp) {
  final parsed = DateTime.tryParse(
      '${stamp.substring(0, 4)}-${stamp.substring(4, 6)}-${stamp.substring(6, 8)}T'
      '${stamp.substring(9, 11)}:${stamp.substring(11, 13)}:${stamp.substring(13, 15)}');
  return parsed?.millisecondsSinceEpoch;
}

/// Bytes moved lately, to give a rate.
class _Meter {
  final _samples = <(int, int)>[]; // (when, bytes)
  void add(int now, int bytes) {
    _samples.add((now, bytes));
    while (_samples.isNotEmpty && now - _samples.first.$1 > _rateWindowMs) {
      _samples.removeAt(0);
    }
  }

  /// Bytes per second over the last seconds.
  int rate(int now) {
    var sum = 0;
    for (final (at, bytes) in _samples) {
      if (now - at <= _rateWindowMs) sum += bytes;
    }
    return sum ~/ (_rateWindowMs ~/ 1000);
  }
}

/// What a member still lacks from us, or we from it, as of the last plan.
class _Need {
  int sendFiles = 0, sendBytes = 0, sendChanges = 0;
  int receiveFiles = 0, receiveBytes = 0, receiveChanges = 0;
  int skipped = 0; // paths it holds back
}

class _Pull {
  _Pull(this.target, this.sources, this.temp, this.file);
  FileEntry target;
  List<String> sources;
  final String temp;
  RandomAccessFile? file;
  final missing = <int>[]; // blocks still to fetch
  final requested = <int>{};
  bool keepOld = false; // set the file it replaces aside (a conflict resolved for theirs)
  int lastProgress = 0;
}

class _Folder {
  _Folder(this.state);
  final SyncFolder state;
  String root = ''; // real path; empty if missing
  bool scanning = false;
  bool rescanSoon = true;
  int nextCleanup = 0; // of .synctrash
  int nextScan = 0;
  bool dirty = false; // state to save
  bool replan = true; // decisions to make again
  int nextPlan = 0; // planning a large folder is paced by how long it takes
  // Every block of every file here, by hash: where a fetch can copy it from.
  // Built once per change of the index, not once per fetch started.
  Map<String, (String, int)>? blockIndex;
  int blockIndexSeq = -1;
  final pulls = SplayTreeMap<String, _Pull>();
  final blocked = <String, String>{}; // path -> why it cannot be applied now
  final logged = <String>{}; // things already told
  List<Map<String, Object?>> conflicts = [];
  List<Map<String, Object?>> held = []; // [{path, reason}]: present here but not synced
  String lastStatus = '';
  String lastState = '';
  int lastEmit = -1 << 30;
  int needFiles = 0, needBytes = 0;
  List<String> queued = []; // files to fetch that have not started
  Map<String, LeftOut> leftOut = {}; // by the last scan
  // The large-delete guard.
  List<String> pendingDeletes = [];
  final approvedDeletes = <String>{};
  int free = -1; // bytes left on the disk, looked up now and then
  int nextFree = 0;
  bool freePending = false;
  final needs = <String, _Need>{}; // by key
}

class _Out {
  _Out.control(this.control)
      : id = 0,
        data = null,
        size = jsonEncode(control).length;
  _Out.data(this.id, Uint8List this.data)
      : control = null,
        size = data.length + 5;
  final Map<String, Object?>? control;
  final int id;
  final Uint8List? data;
  final int size;
}

class _Peer {
  _Peer(this.key);
  final String key;
  final sent = <String, int>{}; // folder -> our seq the peer has
  final helloSent = <String>{};
  final listening = <String>{}; // folders it asked for our index of
  final heard = <String>{}; // folders whose index it has sent us
  final queue = Queue<_Out>();
  int inflight = 0; // block requests to it
  final received = _Meter(), served = _Meter();
  String serving = ''; // the file it last asked a block of
  String servingFolder = '';
  int servedAt = -1 << 30;
}

class _Request {
  _Request(this.dev, this.folder, this.path, this.block, this.hash,
      this.expected, this.deadline);
  final String dev;
  final String folder;
  final String path;
  final int block;
  final Uint8List hash;
  final int expected;
  final data = BytesBuilder(copy: false);
  int deadline;
}

int? _integer(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt();
  return null;
}

/// Where a path really leads, with every link along it followed; empty if it
/// does not exist.
String realPath(String path) {
  try {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return '';
    return type == FileSystemEntityType.directory
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return '';
  }
}

bool _isWithin(String path, String root) {
  String norm(String s) => pathsIgnoreCase ? s.toLowerCase() : s;
  final p = norm(path), r = norm(root);
  if (p == r) return true;
  final sep = Platform.pathSeparator;
  return p.startsWith(r.endsWith(sep) ? r : '$r$sep');
}

String _dirName(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i <= 0 ? path : path.substring(0, i);
}

bool _isLink(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.link;

String _two(int n) => n.toString().padLeft(2, '0');

String _stampNow() {
  final t = DateTime.now();
  return '${t.year.toString().padLeft(4, '0')}${_two(t.month)}${_two(t.day)}-'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';
}

String _uniquePath(String folder, String name) {
  var candidate = '$folder${Platform.pathSeparator}$name';
  if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return candidate;
  }
  final dot = name.lastIndexOf('.');
  final base = dot < 0 ? name : name.substring(0, dot);
  final suffix = dot < 0 ? '' : name.substring(dot + 1);
  for (var n = 1;; n++) {
    candidate = '$folder${Platform.pathSeparator}'
        '${suffix.isEmpty ? '$base ($n)' : '$base ($n).$suffix'}';
    if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return candidate;
    }
  }
}

// Kept files older than the cutoff go (mobile has no system trash); folders
// left empty go too. Runs in another isolate.
int _cleanKeptDir(String root, int cutoffMs) {
  final stamp = RegExp(r'~(\d{8}-\d{6})(?:\.[^.]*)?$');
  var gone = 0;
  void clean(String dir) {
    List<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final fe in children) {
      if (fe is Link) continue;
      if (fe is Directory) {
        clean(fe.path);
        try {
          fe.deleteSync(); // only if it is empty now
        } on FileSystemException {
          // still holds something
        }
        continue;
      }
      final m = stamp.firstMatch(baseName(fe.path));
      int when;
      if (m != null) {
        final s = m.group(1)!;
        final parsed = DateTime.tryParse(
            '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}T'
            '${s.substring(9, 11)}:${s.substring(11, 13)}:${s.substring(13, 15)}');
        if (parsed == null) continue;
        when = parsed.millisecondsSinceEpoch;
      } else {
        try {
          when = fe.statSync().modified.millisecondsSinceEpoch;
        } on FileSystemException {
          continue;
        }
      }
      if (when > cutoffMs) continue;
      try {
        fe.deleteSync();
        gone++;
      } on FileSystemException {
        // try again next time
      }
    }
  }

  clean(root);
  return gone;
}

class SyncService {
  SyncService({
    required bool Function(String dev, Map<String, Object?> msg) sendControl,
    required bool Function(String dev, int requestId, Uint8List bytes) sendData,
    required String? Function(String dev) peerKey,
    required int Function(String dev) connectedSince,
    required String myKeyHex,
    required String stateDir,
    Future<int> Function(String path)? freeSpace,
  })  : _sendControl = sendControl,
        _sendData = sendData,
        _peerKey = peerKey,
        _since = connectedSince,
        _freeSpace = freeSpace,
        _me = memberIdOf(myKeyHex),
        _stateDir = stateDir {
    try {
      Directory(stateDir).createSync(recursive: true);
    } on FileSystemException {
      // saving will fail and say nothing; sync still runs
    }
    _clock.start();
  }

  final bool Function(String, Map<String, Object?>) _sendControl;
  final bool Function(String, int, Uint8List) _sendData;
  final String? Function(String) _peerKey;
  final int Function(String) _since;
  final Future<int> Function(String)? _freeSpace;
  final String _me;
  final String _stateDir;

  // Tests.
  int scanIntervalMs = 10000;
  int stableAfterMs = 2000;
  int keepDays = 30; // files kept in .synctrash go after this many days
  // The large-delete guard: holds back a round of deletes of at least
  // [guardMin] paths that is also at least [guardShare] of the folder's
  // files, or [guardMany] paths however large the folder. 0 turns it off.
  int guardMin = 10;
  int guardMany = 25;
  double guardShare = 0.5;

  /// Why every folder waits ("wifi", "charging"), or empty: syncing goes on.
  String get suspended => _suspended;
  String _suspended = '';
  set suspended(String reason) {
    if (reason == _suspended) return;
    _suspended = reason;
    for (final id in _folders.keys) {
      _emitStatus(id);
    }
  }

  final _clock = Stopwatch();
  int get _now => _clock.elapsedMilliseconds;

  final _folders = SplayTreeMap<String, _Folder>();
  final _peers = <String, _Peer>{};
  final _devOfKey = <String, String>{};
  final _requests = SplayTreeMap<int, _Request>();
  int _nextRequest = 1;
  int _lastSave = 0;
  Timer? _workTimer;
  Timer? _pumpTimer;
  bool _disposed = false;

  final _offers = StreamController<SyncOffers>.broadcast();
  final _folderChanged = StreamController<String>.broadcast();
  final _events = StreamController<SyncEvent>.broadcast();

  Stream<SyncOffers> get offers => _offers.stream;
  Stream<String> get folderChanged => _folderChanged.stream;
  Stream<SyncEvent> get events => _events.stream;

  void _event(String folderId, String path, String kind) {
    if (!_events.isClosed) _events.add(SyncEvent(folderId, path, kind));
  }

  void _openFolder(FolderConfig config) {
    final f = _Folder(SyncFolder(
        config, _me, '$_stateDir${Platform.pathSeparator}${config.id}.json'));
    f.state.load();
    f.state.config = config;
    f.root = realPath(config.path);
    _folders[config.id] = f;
  }

  /// The folders this device takes part in. A folder no longer listed is
  /// left: its state is forgotten, its files stay.
  void setFolders(List<FolderConfig> configs) {
    if (_disposed) return;
    final wanted = {for (final c in configs) c.id};
    for (final id in _folders.keys.toList()) {
      final f = _folders[id]!;
      final moved = configs.any((c) => c.id == id && c.path != f.state.config.path);
      if (wanted.contains(id) && !moved) continue;
      for (final p in f.pulls.values) {
        _close(p);
      }
      _requests.removeWhere((_, r) {
        if (r.folder != id) return false;
        final peer = _peers[r.dev];
        if (peer != null) peer.inflight--;
        return true;
      });
      f.state.removeState();
      _folders.remove(id);
      for (final peer in _peers.values) {
        peer.sent.remove(id);
        peer.helloSent.remove(id);
        peer.listening.remove(id);
      }
    }
    for (final c in configs) {
      final f = _folders[c.id];
      var before = const <String, Grant>{};
      if (f != null) {
        before = f.state.config.peers;
        f.state.config = c;
        f.replan = true;
      } else {
        _openFolder(c);
      }
      // A peer that is no longer sent the folder stops getting its index
      // (the offers tell it to forget what it had); one whose grants changed
      // is greeted again, so both sides learn where they stand.
      for (final peer in _peers.values) {
        final g = c.grantOf(peer.key);
        if (!g.sends) peer.listening.remove(c.id);
        if (g != (before[peer.key] ?? const Grant())) peer.helloSent.remove(c.id);
      }
    }
    for (final dev in _peers.keys.toList()) {
      _sendOffers(dev);
      _sendHellos(dev);
    }
    if (_folders.isNotEmpty && _workTimer == null) {
      _workTimer = Timer.periodic(_workEvery, (_) => _work());
    }
    for (final id in _folders.keys) {
      _emitStatus(id);
    }
  }

  // --- peers -------------------------------------------------------------------

  /// A peer connected, proved who it is, or its grants changed.
  void peerUp(String dev) {
    if (_disposed) return;
    final key = _peerKey(dev) ?? '';
    if (key.isEmpty) {
      if (_peers.containsKey(dev)) peerGone(dev);
      return;
    }
    final existing = _peers[dev];
    if (existing != null && existing.key != key) peerGone(dev);
    if (!_peers.containsKey(dev)) {
      _peers[dev] = _Peer(key);
      _devOfKey[key] = dev;
    }
    _sendOffers(dev);
    _sendHellos(dev);
    _sawPeer(key);
  }

  // Remembers when a member was last connected.
  void _sawPeer(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final f in _folders.values) {
      f.replan = true;
      if (f.state.config.peers.containsKey(key)) {
        (f.state.peerStats[key] ??= PeerStats()).lastSeen = now;
        f.dirty = true;
      }
    }
  }

  void peerGone(String dev) {
    final peer = _peers[dev];
    if (peer == null) return;
    final failed = [
      for (final e in _requests.entries)
        if (e.value.dev == dev) e.key
    ];
    for (final id in failed) {
      _failRequest(id, false);
    }
    _peers.remove(dev);
    if (_devOfKey[peer.key] == dev) _devOfKey.remove(peer.key);
    if (!_offers.isClosed) _offers.add(SyncOffers(peer.key, const []));
    _sawPeer(peer.key);
  }

  int _sinceOf(String key) {
    final dev = _devOfKey[key];
    return dev == null ? -1 : _since(dev);
  }

  void _sendOffers(String dev) {
    final peer = _peers[dev];
    if (peer == null) return;
    final offers = [
      for (final e in _folders.entries)
        if (e.value.state.config.grantOf(peer.key).sends)
          {'id': e.key, 'label': e.value.state.config.label}
    ];
    _enqueue(dev, _Out.control({'t': 'sync.offers', 'folders': offers}));
  }

  // `reply`: answering the peer's hello; a reply is never answered.
  void _sendHellos(String dev, [bool reply = false]) {
    final peer = _peers[dev];
    if (peer == null) return;
    _folders.forEach((id, f) {
      final g = f.state.config.grantOf(peer.key);
      if ((!g.sends && !g.accepts) || peer.helloSent.contains(id)) return;
      peer.helloSent.add(id);
      final r = f.state.remotes[peer.key];
      _enqueue(
          dev,
          _Out.control({
            't': 'sync.hello',
            'folder': id,
            'epoch': f.state.epochString,
            'peerEpoch': r == null ? '' : r.epoch,
            'seen': r == null ? 0 : r.seen,
            'reply': reply,
          }));
    });
  }

  void _onHello(String dev, Map<String, Object?> msg) {
    final peer = _peers[dev];
    if (peer == null) return;
    final id = msg['folder'] is String ? msg['folder'] as String : '';
    final f = _folders[id];
    if (f == null) return;
    final g = f.state.config.grantOf(peer.key);
    if (g.sends) {
      // It has our index up to `seen`, unless our index started over since.
      final same = msg['peerEpoch'] == f.state.epochString;
      final seen = _integer(msg['seen']) ?? 0;
      peer.sent[id] = same ? (seen < 0 ? 0 : seen) : 0;
      peer.listening.add(id);
      _sendIndex(dev, id, !same);
    }
    // Our hello may have arrived before it had this folder: until its index
    // comes, answer with ours so it knows to send it. Replies are not
    // answered, so two devices cannot keep this going.
    final reply = msg['reply'] != true && g.accepts && !peer.heard.contains(id);
    if (reply) peer.helloSent.remove(id);
    if (g.sends || g.accepts) _sendHellos(dev, reply);
  }

  void _sendIndex(String dev, String folderId, bool full) {
    final peer = _peers[dev];
    final f = _folders[folderId];
    if (peer == null || f == null) return;
    final sent = peer.sent[folderId] ?? 0;
    if (!full && f.state.seq <= sent) return;
    final changed = f.state.changedSince(full ? 0 : sent);
    final epoch = f.state.epochString;
    var batch = <Map<String, Object?>>[];
    var size = 0;
    var first = true;
    void flush() {
      _enqueue(
          dev,
          _Out.control({
            't': 'sync.index',
            'folder': folderId,
            'epoch': epoch,
            'full': full && first,
            'entries': batch,
          }));
      first = false;
      batch = [];
      size = 0;
    }

    for (final e in changed) {
      batch.add(e.toJson());
      size += 200 + e.blocks.length * 66 + e.path.length;
      if (size >= _indexBatch) flush();
    }
    if (batch.isNotEmpty || (full && first)) flush();
    peer.sent[folderId] = f.state.seq;
    final stats = f.state.peerStats[peer.key] ??= PeerStats();
    if (stats.sentSeq != f.state.seq) {
      stats.sentSeq = f.state.seq;
      f.dirty = true;
      f.replan = true; // what the peer still lacks changed
    }
  }

  void _onIndex(String dev, Map<String, Object?> msg) {
    final peer = _peers[dev];
    if (peer == null) return;
    final id = msg['folder'] is String ? msg['folder'] as String : '';
    final f = _folders[id];
    if (f == null || !f.state.config.grantOf(peer.key).accepts) return;
    peer.heard.add(id);
    final entries = <FileEntry>[];
    final list = msg['entries'];
    if (list is List) {
      for (final v in list) {
        if (v is! Map) continue;
        final e = FileEntry.fromJson(v.cast<String, Object?>());
        if (e != null) entries.add(e);
      }
    }
    f.state.applyRemote(
        peer.key, canonicalEpoch(msg['epoch']), msg['full'] == true, entries);
    f.dirty = true;
    f.replan = true;
  }

  // --- sending -------------------------------------------------------------------

  void _enqueue(String dev, _Out out) {
    final peer = _peers[dev];
    if (peer == null) return;
    peer.queue.add(out);
    _pumpTimer ??= Timer(Duration.zero, _pump);
  }

  void _pump() {
    _pumpTimer = null;
    if (_disposed) return;
    var budget = _pumpBudget;
    var pending = false;
    for (final e in _peers.entries.toList()) {
      final peer = e.value;
      while (peer.queue.isNotEmpty && budget > 0) {
        final out = peer.queue.first;
        final ok = out.control != null
            ? _sendControl(e.key, out.control!)
            : _sendData(e.key, out.id, out.data!);
        if (!ok) break; // its queue is full; later
        budget -= out.size;
        peer.queue.removeFirst();
      }
      pending = pending || peer.queue.isNotEmpty;
    }
    if (pending) {
      _pumpTimer = Timer(Duration(milliseconds: budget > 0 ? 10 : 0), _pump);
    }
  }

  // --- the work loop ---------------------------------------------------------------

  void _work() {
    if (_disposed) return;
    final now = _now;
    final late = [
      for (final e in _requests.entries)
        if (now > e.value.deadline) e.key
    ];
    for (final id in late) {
      _failRequest(id, true);
    }
    for (final id in _folders.keys.toList()) {
      final f = _folders[id];
      if (f == null || f.state.config.paused || _suspended.isNotEmpty) continue;
      // Planning need not wait for a scan: a scan's result leaves alone
      // whatever changed after it began. Every finished fetch asks for
      // another round; a round over a large folder takes a while, so the
      // next waits a few times that long rather than running every tick.
      if (f.replan && now >= f.nextPlan) {
        final began = _now;
        _plan(id);
        final took = _now - began;
        f.nextPlan = _now + (took * 4 < _maxPlanPauseMs ? took * 4 : _maxPlanPauseMs);
      }
      if (now >= f.nextCleanup) _cleanKept(id);
      if (!f.scanning && (f.rescanSoon || now >= f.nextScan)) _startScan(id);
      _requestBlocks(id);
      if (now >= f.nextFree && !f.freePending) {
        f.nextFree = now + _freeEveryMs;
        final ask = _freeSpace;
        if (ask == null || f.root.isEmpty) {
          f.free = -1;
        } else {
          f.freePending = true;
          ask(f.root).then((v) {
            f.free = v;
          }, onError: (Object _) {
            f.free = -1;
          }).whenComplete(() => f.freePending = false);
        }
      }
    }
    for (final e in _peers.entries.toList()) {
      for (final id in e.value.listening.toList()) {
        _sendIndex(e.key, id, false);
      }
    }
    // The state file is the whole index; while fetches are running it changes
    // with every file, and a rescan rebuilds it anyway, so it is written less
    // often then.
    final fetching = _folders.values.any((f) => f.pulls.isNotEmpty);
    if (now - _lastSave >= (fetching ? _saveWhileFetchingMs : _saveEveryMs)) {
      _lastSave = now;
      for (final f in _folders.values) {
        if (f.dirty) {
          f.state.save();
          f.dirty = false;
        }
      }
    }
    for (final id in _folders.keys) {
      _emitStatus(id);
    }
  }

  void _startScan(String folderId) {
    final f = _folders[folderId];
    if (f == null) return;
    f.root = realPath(f.state.config.path);
    f.rescanSoon = false;
    f.nextScan = _now + scanIntervalMs;
    if (f.root.isEmpty) return;
    final input = ScanInput(f.root, Map.of(f.state.local),
        stableAfterMs: stableAfterMs);
    f.scanning = true;
    final seqAtStart = f.state.seq;
    final expected = f.state;
    scanFolderInBackground(input).then((result) {
      final g = _folders[folderId];
      if (_disposed || g == null || !identical(g.state, expected)) return; // left meanwhile
      g.scanning = false;
      if (!result.ok) return;
      if (g.state.applyScan(result, seqAtStart) > 0) g.dirty = true;
      g.leftOut = result.leftOut;
      g.blocked.clear(); // what was in the way may be gone
      g.replan = true;
    }, onError: (Object _) {
      final g = _folders[folderId];
      if (g != null && identical(g.state, expected)) g.scanning = false;
    });
  }

  void _plan(String folderId) {
    final f = _folders[folderId];
    if (f == null || f.root.isEmpty) return;
    f.replan = false;
    // The rules as they are on disk now; a scan that began before they
    // changed would bring back the old ones.
    final ignoreText = readSmallFile(joinPath(f.root, kIgnoreFile));
    if (ignoreText != f.state.ignore.text) f.state.ignore = IgnoreRules(ignoreText);
    final skipText = readSmallFile(joinPath(f.root, kSkipFile));
    if (skipText != f.state.skip.text) f.state.skip = IgnoreRules(skipText);

    final decisions = <String, Decision>{};
    for (final path in f.state.allPaths()) {
      final d = f.state.decide(path, _sinceOf);
      if (d.kind != DecisionKind.none) decisions[path] = d;
    }

    // Names that clash, ignoring case, with an older one are held back here:
    // not fetched, and if they are files of ours, marked skipped. When the
    // older one goes, they come back at the next scan.
    final clashes = f.state.clashes(decisions);
    for (final k in f.state.clashHeld.keys) {
      if (!clashes.containsKey(k)) f.rescanSoon = true; // released
    }
    f.state.clashHeld = clashes;
    for (final path in clashes.keys) {
      decisions.remove(path);
      final l = f.state.local[path];
      if (l != null && !l.deleted && !l.skipped) {
        f.state.setLocal(l.copy()..skipped = true);
        f.dirty = true;
      }
    }
    // Tell the user once about each thing held back, and why.
    final heldPaths = {...f.state.scanHeld.keys, ...clashes.keys}.toList()..sort();
    final held = <Map<String, Object?>>[];
    for (final path in heldPaths) {
      final reason = f.state.heldReason(path);
      held.add({'path': path, 'reason': reason});
      if (f.logged.add('$path|$reason')) _event(folderId, path, 'held:$reason');
    }
    f.held = held;

    final deletes = <Decision>[], dirs = <Decision>[], files = <Decision>[];
    final adopts = <(String, Decision)>[];
    final conflicts = <Map<String, Object?>>[];
    final paths = decisions.keys.toList()..sort();
    for (final path in paths) {
      final d = decisions[path]!;
      if (d.kind == DecisionKind.conflict) {
        conflicts.add({
          'path': path,
          'involved': d.involved,
          'following': d.following,
          'waiting': d.waiting,
          'candidates': [
            for (final c in d.candidates)
              {
                'key': c.key,
                'mine': c.key.isEmpty,
                'size': c.entry.size,
                'mtime': c.entry.mtime,
                'deleted': c.entry.deleted,
                'dir': c.entry.dir,
              }
          ],
        });
        // Tell the user once per set of competing versions.
        final signature = StringBuffer(path);
        for (final c in d.candidates) {
          for (final v in (c.entry.version.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))) {
            signature.write('|${v.key}:${v.value}');
          }
        }
        if (f.logged.add(signature.toString())) {
          _event(
              folderId,
              path,
              d.involved
                  ? 'conflict'
                  : d.apply
                      ? 'following:${d.following}'
                      : d.waiting
                          ? 'waiting'
                          : 'kept');
        }
        if (!d.apply) continue;
      }
      if (f.blocked.containsKey(path)) continue;
      if (d.kind == DecisionKind.adopt) {
        adopts.add((path, d));
      } else if (d.target.deleted) {
        deletes.add(d);
      } else if (d.target.dir) {
        dirs.add(d);
      } else {
        files.add(d);
      }
    }
    f.conflicts = conflicts;

    for (final (path, d) in adopts) {
      f.state.setLocal(d.target);
      f.state.forced.remove(path);
    }
    // Folders top-down.
    for (final d in dirs) {
      _apply(f, folderId, d);
    }

    // Renames: a new name whose content is that of a file about to be deleted
    // here is the same file, moved. Rename it in place rather than assembling
    // a copy and setting the original aside. A change of case only is one too.
    for (var i = 0; i < files.length;) {
      final file = files[i];
      final had = f.state.local[file.target.path];
      final fresh = had == null || had.deleted;
      int? from;
      if (fresh && !f.pulls.containsKey(file.target.path)) {
        for (var j = 0; j < deletes.length; j++) {
          final l = f.state.local[deletes[j].target.path];
          if (l == null || l.deleted || l.dir || !l.sameContent(file.target)) continue;
          // Prefer the same name in another case: that is surely the one.
          if (from == null ||
              foldName(deletes[j].target.path) == foldName(file.target.path)) {
            from = j;
          }
        }
      }
      if (from != null && _renameLocal(f, deletes[from].target.path, file.target)) {
        final del = deletes.removeAt(from);
        f.state.setLocal(del.target);
        f.state.forced.remove(del.target.path);
        f.state.forced.remove(file.target.path);
        files.removeAt(i);
        f.dirty = true;
        f.replan = true;
      } else {
        i++;
      }
    }

    // Fetches no longer wanted, or wanted with other contents.
    for (final path in f.pulls.keys.toList()) {
      final pull = f.pulls[path]!;
      final want = files.where((d) => d.target.path == path).firstOrNull;
      if (want == null || !want.target.sameContent(pull.target)) {
        _dropPull(f, path);
      } else {
        pull.target = want.target; // perhaps a newer version of the same content
        pull.sources = want.sources;
      }
    }

    // Fetches start before any delete: starting one copies the blocks it can
    // from files here, which may be the very files about to go.
    f.needFiles = 0;
    f.needBytes = 0;
    f.queued = [];
    var allStarted = true;
    var newRules = false;
    for (final d in files) {
      final path = d.target.path;
      f.needFiles++;
      f.needBytes += d.target.size;
      if (!f.pulls.containsKey(path) && !f.blocked.containsKey(path)) {
        if (f.pulls.length < _maxPulls) {
          _startPull(f, folderId, d.target, d.sources);
        } else {
          allStarted = false;
        }
      }
      if (!f.pulls.containsKey(path)) f.queued.add(path);
      if (path == kIgnoreFile && f.pulls.containsKey(path)) newRules = true;
    }
    // Deletes bottom-up, once every fetch has taken what it needs from here,
    // and not while new ignore rules are on the way: what they ignore is not
    // to be deleted here. A round that would remove much of the folder at
    // once (a device wiped its copy, say) waits for the user instead.
    final pending = <String>[];
    var applied = 0;
    if (allStarted && !newRules) {
      deletes.sort((a, b) => b.target.path.compareTo(a.target.path));
      var live = 0;
      for (final e in f.state.local.values) {
        if (!e.deleted) live++;
      }
      final n = deletes.length;
      final guarded = guardMin > 0 &&
          n >= guardMin &&
          (n >= guardMany || n >= guardShare * (live < 1 ? 1 : live));
      for (final d in deletes) {
        if (guarded && !f.approvedDeletes.contains(d.target.path)) {
          pending.add(d.target.path);
          continue;
        }
        _apply(f, folderId, d);
        f.approvedDeletes.remove(d.target.path);
        applied++;
      }
      if (pending.isEmpty) f.approvedDeletes.clear();
    } else if (deletes.isNotEmpty) {
      f.replan = true;
    }
    pending.sort();
    if (pending.isNotEmpty) {
      final signature = 'deletes|${pending.join('|')}';
      if (f.logged.add(signature)) _event(folderId, '', 'deletes:${pending.length}');
    }
    f.pendingDeletes = pending;
    if (adopts.isNotEmpty || dirs.isNotEmpty || applied > 0) {
      f.dirty = true;
      f.replan = true; // settles in another round
    }

    // What each member still lacks from us, or we from it; and when there
    // was nothing either way while it was connected.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    f.state.config.peers.forEach((key, g) {
      final need = _Need();
      if (g.sends) {
        for (final e in f.state.local.values) {
          if (e.skipped || !_pendingFor(f, e, key)) continue;
          if (e.deleted || e.dir) {
            need.sendChanges++;
          } else {
            need.sendFiles++;
            need.sendBytes += e.size;
          }
        }
      }
      if (g.accepts) {
        for (final d in files) {
          if (d.sources.contains(key)) {
            need.receiveFiles++;
            need.receiveBytes += d.target.size;
          }
        }
        for (final d in deletes) {
          if (d.sources.contains(key) || d.following == key) need.receiveChanges++;
        }
        for (final d in dirs) {
          if (d.following == key) need.receiveChanges++;
        }
      }
      final r = f.state.remotes[key];
      if (r != null) {
        for (final e in r.entries.values) {
          if (e.skipped) need.skipped++;
        }
      }
      f.needs[key] = need;
      if (need.sendFiles + need.sendChanges + need.receiveFiles + need.receiveChanges == 0 &&
          _devOfKey.containsKey(key) &&
          !f.scanning) {
        final stats = f.state.peerStats[key] ??= PeerStats();
        if (nowMs ~/ 60000 != stats.lastInSync ~/ 60000) f.dirty = true; // saved once a minute
        stats.lastInSync = nowMs;
      }
    });
    f.needs.removeWhere((key, _) => !f.state.config.peers.containsKey(key));
  }

  // Whether a change of ours (its entry) has yet to reach the peer with `key`:
  // by its index when it sends us one, else by how far ours reached it.
  bool _pendingFor(_Folder f, FileEntry e, String key) {
    final r = f.state.remotes[key];
    if (r != null) {
      final theirs = r.entries[e.path];
      if (theirs == null) return !e.deleted;
      if (theirs.skipped) return false;
      return compareVersions(theirs.version, e.version) == Order.older;
    }
    var sentSeq = f.state.peerStats[key]?.sentSeq ?? 0;
    final peer = _peerOf(key);
    if (peer != null) {
      final live = peer.sent[f.state.config.id] ?? 0;
      if (live > sentSeq) sentSeq = live;
    }
    return e.seq > sentSeq;
  }

  _Peer? _peerOf(String key) {
    final dev = _devOfKey[key];
    return dev == null ? null : _peers[dev];
  }

  // Moves the file at `from` to `to.path`, if the disk still holds what the
  // index says and nothing else is at the new name (or it is the same file
  // under another case).
  bool _renameLocal(_Folder f, String from, FileEntry to) {
    final caseOnly = foldName(from) == foldName(to.path);
    final slash = to.path.lastIndexOf('/');
    final parent = slash < 0 ? '' : to.path.substring(0, slash);
    if (_caseMismatch(f, caseOnly ? parent : to.path).isNotEmpty) return false;
    if (!_diskMatches(f, from) || !_safeParent(f, to.path, true)) return false;
    final absFrom = _absolute(f, from), absTo = _absolute(f, to.path);
    final targetExists = FileSystemEntity.typeSync(absTo, followLinks: false) !=
        FileSystemEntityType.notFound;
    if (targetExists && !caseOnly) return false;
    try {
      if (caseOnly) {
        // A case-insensitive disk sees the new name as taken by this very
        // file; going through another name works everywhere.
        final step = '${_dirName(absFrom)}${Platform.pathSeparator}'
            '${kPartPrefix}rename-${baseName(absFrom)}';
        File(absFrom).renameSync(step);
        try {
          File(step).renameSync(absTo);
        } on FileSystemException {
          File(step).renameSync(absFrom);
          return false;
        }
      } else {
        File(absFrom).renameSync(absTo);
      }
    } on FileSystemException {
      return false;
    }
    try {
      File(absTo).setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(to.mtime));
    } on FileSystemException {
      // the time stays as it was; the index takes what the disk says
    }
    f.state.setLocal(to.copy()..mtime = _mtimeOf(absTo));
    return true;
  }

  // --- applying decisions ----------------------------------------------------------

  String _absolute(_Folder f, String path) => joinPath(f.root, path);

  int _mtimeOf(String abs) {
    try {
      return FileStat.statSync(abs).modified.millisecondsSinceEpoch;
    } on FileSystemException {
      return 0;
    }
  }

  // The first part of `path` that is on disk only under another case (a disk
  // that ignores case finds it anyway); empty if there is none.
  String _caseMismatch(_Folder f, String path) {
    var dir = f.root;
    var rel = '';
    for (final part in path.split('/')) {
      if (part.isEmpty) return '';
      final next = '$dir${Platform.pathSeparator}$part';
      if (FileSystemEntity.typeSync(next, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return ''; // the rest is not there yet
      }
      rel = rel.isEmpty ? part : '$rel/$part';
      List<String> names;
      try {
        names = [
          for (final e in Directory(dir).listSync(followLinks: false))
            Platform.isMacOS ? nfc(baseName(e.path)) : baseName(e.path)
        ];
      } on FileSystemException {
        return '';
      }
      if (!names.contains(part)) return rel; // found only by ignoring case
      dir = next;
    }
    return '';
  }

  // The disk still holds what the index says, so changing it loses nothing
  // the scanner has not seen.
  bool _diskMatches(_Folder f, String path) {
    final abs = _absolute(f, path);
    final type = FileSystemEntity.typeSync(abs, followLinks: false);
    if (type == FileSystemEntityType.link) return false;
    final l = f.state.local[path];
    // Not ours: nothing there, or only something under another case, which
    // the callers keep clear of.
    if (l == null || l.deleted) {
      return type == FileSystemEntityType.notFound ||
          _caseMismatch(f, path).isNotEmpty;
    }
    if (l.skipped) return false;
    if (l.dir) return type == FileSystemEntityType.directory;
    if (type != FileSystemEntityType.file) return false;
    final st = FileStat.statSync(abs);
    return st.size == l.size && st.modified.millisecondsSinceEpoch == l.mtime;
  }

  // The folder `path` goes in is inside the synced folder, links resolved.
  bool _safeParent(_Folder f, String path, bool create) {
    final parent = _dirName(_absolute(f, path));
    if (create) {
      try {
        Directory(parent).createSync(recursive: true);
      } on FileSystemException {
        return false;
      }
    }
    final real = realPath(parent);
    return real.isNotEmpty && _isWithin(real, f.root);
  }

  void _block(_Folder f, String folderId, String path, String reason) {
    if (f.logged.add('$path|blocked:$reason')) {
      _event(folderId, path, 'blocked:$reason'); // told once, though retried
    }
    f.blocked[path] = reason;
  }

  void _apply(_Folder f, String folderId, Decision d) {
    final path = d.target.path;
    final abs = _absolute(f, path);
    final otherCase = _caseMismatch(f, path).isNotEmpty;
    if (otherCase && !d.target.deleted) return _block(f, folderId, path, 'clash');
    if (!_safeParent(f, path, d.target.dir)) {
      return _block(f, folderId, path, 'outside');
    }
    final type = FileSystemEntity.typeSync(abs, followLinks: false);

    if (d.target.dir) {
      if (type == FileSystemEntityType.directory) {
        f.state.setLocal(d.target);
      } else if (type != FileSystemEntityType.notFound) {
        f.rescanSoon = true;
        return _block(f, folderId, path, 'in_the_way');
      } else {
        try {
          Directory(abs).createSync();
          f.state.setLocal(d.target);
        } on FileSystemException {
          return _block(f, folderId, path, 'io');
        }
      }
      f.state.forced.remove(path);
      return;
    }

    // A delete.
    if (!_diskMatches(f, path)) {
      f.rescanSoon = true; // changed here meanwhile: the scan will make it a conflict
      return _block(f, folderId, path, 'changed');
    }
    if (type != FileSystemEntityType.notFound && !otherCase) {
      // Under another case it is a different file of ours.
      if (type == FileSystemEntityType.directory) {
        try {
          if (Directory(abs).listSync().isNotEmpty) {
            return _block(f, folderId, path, 'not_empty'); // holds files that are not synced
          }
          Directory(abs).deleteSync(); // an empty folder just goes
        } on FileSystemException {
          return _block(f, folderId, path, 'io');
        }
      } else if (!_keepAside(f, path)) {
        // Files are kept aside for a while.
        try {
          File(abs).deleteSync();
        } on FileSystemException {
          return _block(f, folderId, path, 'io');
        }
      }
    }
    f.state.setLocal(d.target);
    f.state.forced.remove(path);
  }

  void _startPull(_Folder f, String folderId, FileEntry target, List<String> sources) {
    final path = target.path;
    // A file or folder of ours under another case holds this name on a disk
    // that does not tell case apart: it is held back, and this cannot be
    // written over or into it. Nothing to retry until one of them goes.
    if (_caseMismatch(f, path).isNotEmpty) return _block(f, folderId, path, 'clash');
    if (!_safeParent(f, path, true)) return _block(f, folderId, path, 'outside');
    if (!_diskMatches(f, path)) {
      f.rescanSoon = true;
      return _block(f, folderId, path, 'changed');
    }
    final abs = _absolute(f, path);
    final temp = '${_dirName(abs)}${Platform.pathSeparator}$kPartPrefix'
        '${bytesToHex(target.hash).substring(0, 8)}-${baseName(abs)}';
    RandomAccessFile file;
    int had;
    try {
      // Read and write, keeping what an earlier attempt left.
      file = File(temp).openSync(mode: FileMode.append);
      had = file.lengthSync();
      file.truncateSync(target.size);
    } on FileSystemException {
      return _block(f, folderId, path, 'io');
    }
    final p = _Pull(target, List.of(sources), temp, file)
      ..keepOld = f.state.forced.containsKey(path); // our own version, given up in a conflict

    // Where each block can come from without the network: the part file of an
    // earlier attempt, or any file here that has it (a rename, a copy, an
    // earlier version).
    final localBlocks = _blockIndex(f);
    for (var i = 0; i < target.blocks.length; i++) {
      final offset = i * target.blockSize;
      final length = target.blockLength(i);
      try {
        if (offset < had) {
          file.setPositionSync(offset);
          if (bytesEqual(sha256Of(file.readSync(length)), target.blocks[i])) continue;
        }
      } on FileSystemException {
        // read it from elsewhere
      }
      var found = false;
      final from = localBlocks[bytesToHex(target.blocks[i])];
      if (from != null) {
        try {
          final src = File(_absolute(f, from.$1)).openSync();
          try {
            src.setPositionSync(from.$2);
            final data = src.readSync(length);
            if (bytesEqual(sha256Of(data), target.blocks[i])) {
              file.setPositionSync(offset);
              file.writeFromSync(data);
              found = true;
            }
          } finally {
            src.closeSync();
          }
        } on FileSystemException {
          // fetch it instead
        }
      }
      if (!found) p.missing.add(i);
    }
    p.lastProgress = _now;
    f.pulls[path] = p;
    if (p.missing.isEmpty) _finishPull(folderId, path);
  }

  Map<String, (String, int)> _blockIndex(_Folder f) {
    if (f.blockIndex != null && f.blockIndexSeq == f.state.seq) return f.blockIndex!;
    final index = <String, (String, int)>{};
    for (final e in f.state.local.values) {
      if (e.deleted || e.dir || e.skipped) continue;
      for (var i = 0; i < e.blocks.length; i++) {
        index[bytesToHex(e.blocks[i])] = (e.path, i * e.blockSize);
      }
    }
    f.blockIndex = index;
    f.blockIndexSeq = f.state.seq;
    return index;
  }

  void _requestBlocks(String folderId) {
    final f = _folders[folderId];
    if (f == null) return;
    for (final e in f.pulls.entries) {
      final path = e.key, p = e.value;
      for (final i in p.missing) {
        if (p.requested.contains(i)) continue;
        // The connected holder with the fewest requests waiting.
        _Peer? best;
        String? bestDev;
        for (final key in p.sources) {
          final dev = _devOfKey[key];
          if (dev == null) continue;
          final peer = _peers[dev]!;
          if (peer.inflight >= _maxInflight) continue;
          if (best == null || peer.inflight < best.inflight) {
            best = peer;
            bestDev = dev;
          }
        }
        if (best == null) break;
        final id = _nextRequest;
        _nextRequest = _nextRequest >= 0xFFFFFFFF ? 1 : _nextRequest + 1;
        _requests[id] = _Request(bestDev!, folderId, path, i, p.target.blocks[i],
            p.target.blockLength(i), _now + _requestTimeoutMs);
        p.requested.add(i);
        best.inflight++;
        _enqueue(
            bestDev,
            _Out.control({
              't': 'sync.get',
              'id': id,
              'folder': folderId,
              'path': path,
              'block': i,
              'offset': i * p.target.blockSize,
              'size': p.target.blockLength(i),
              'hash': bytesToHex(p.target.blocks[i]),
            }));
      }
    }
  }

  /// A kind-4 frame: part of the block answering request `requestId`.
  void handleData(String dev, int requestId, Uint8List bytes) {
    if (_disposed) return;
    final r = _requests[requestId];
    if (r == null || r.dev != dev) return;
    r.data.add(bytes);
    r.deadline = _now + _requestTimeoutMs;
    if (r.data.length < r.expected) return;

    final f = _folders[r.folder];
    final pull = f?.pulls[r.path];
    final data = r.data.toBytes();
    if (pull == null ||
        data.length != r.expected ||
        !bytesEqual(sha256Of(data), r.hash)) {
      _failRequest(requestId, true); // damaged or unwanted; another holder may do better
      return;
    }
    try {
      pull.file!.setPositionSync(r.block * pull.target.blockSize);
      pull.file!.writeFromSync(data);
    } on Object {
      _failRequest(requestId, false);
      return;
    }
    pull.missing.remove(r.block);
    pull.requested.remove(r.block);
    pull.lastProgress = _now;
    final peer = _peers[dev];
    if (peer != null) {
      peer.inflight--;
      peer.received.add(_now, data.length);
    }
    _requests.remove(requestId);
    if (pull.missing.isEmpty) _finishPull(r.folder, r.path);
  }

  void _onError(String dev, Map<String, Object?> msg) {
    final id = _integer(msg['id']);
    if (id == null) return;
    final r = _requests[id];
    if (r != null && r.dev == dev) _failRequest(id, true);
  }

  void _failRequest(int id, bool dropSource) {
    final r = _requests.remove(id);
    if (r == null) return;
    var key = '';
    final peer = _peers[r.dev];
    if (peer != null) {
      peer.inflight--;
      key = peer.key;
    }
    final p = _folders[r.folder]?.pulls[r.path];
    if (p == null) return;
    p.requested.remove(r.block);
    if (dropSource && key.isNotEmpty) p.sources.remove(key);
  }

  void _close(_Pull p) {
    try {
      p.file?.closeSync();
    } on FileSystemException {
      // already gone
    }
    p.file = null;
  }

  void _finishPull(String folderId, String path) {
    final f = _folders[folderId];
    if (f == null) return;
    final pull = f.pulls.remove(path);
    if (pull == null) return;
    _close(pull);
    try {
      File(pull.temp).setLastModifiedSync(
          DateTime.fromMillisecondsSinceEpoch(pull.target.mtime));
    } on FileSystemException {
      // the time is what the disk gives it
    }
    final abs = _absolute(f, path);
    // Changed here while it was being fetched: keep the part file, rescan,
    // and let the result decide.
    if (!_diskMatches(f, path) || !_safeParent(f, path, false)) {
      f.rescanSoon = true;
      return _block(f, folderId, path, 'changed');
    }
    if (_caseMismatch(f, path).isNotEmpty) return _block(f, folderId, path, 'clash');
    if (pull.keepOld &&
        FileSystemEntity.typeSync(abs, followLinks: false) ==
            FileSystemEntityType.file &&
        !_keepAside(f, path)) {
      return _block(f, folderId, path, 'io');
    }
    try {
      File(pull.temp).renameSync(abs); // replaces the target in one step
    } on FileSystemException {
      return _block(f, folderId, path, 'io');
    }
    f.state.setLocal(pull.target.copy()..mtime = _mtimeOf(abs)); // as the disk keeps it
    f.state.forced.remove(path);
    f.dirty = true;
    f.replan = true;
  }

  // Moves a file into .synctrash, its path kept and the time added to its name.
  bool _keepAside(_Folder f, String path) {
    final slash = path.lastIndexOf('/');
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final base = dot < 0 ? name : name.substring(0, dot);
    final suffix = dot < 0 ? '' : name.substring(dot + 1);
    final kept = '$base~${_stampNow()}${suffix.isEmpty ? '' : '.$suffix'}';
    final dir = joinPath(joinPath(f.root, kKeptDir), slash < 0 ? '' : path.substring(0, slash));
    try {
      Directory(dir).createSync(recursive: true);
      File(_absolute(f, path)).renameSync(_uniquePath(dir, kept));
      return true;
    } on FileSystemException {
      return false;
    }
  }

  // Files kept longer than keepDays go; empty folders left behind go too.
  // Runs in another isolate.
  void _cleanKept(String folderId) {
    final f = _folders[folderId];
    if (f == null) return;
    f.nextCleanup = _now + _cleanEveryMs;
    if (f.root.isEmpty) return;
    final root = joinPath(f.root, kKeptDir);
    if (!Directory(root).existsSync()) return;
    final cutoff = DateTime.now()
        .subtract(Duration(days: keepDays))
        .millisecondsSinceEpoch;
    Isolate.run(() => _cleanKeptDir(root, cutoff)).ignore();
  }

  void _dropPull(_Folder f, String path) {
    final pull = f.pulls.remove(path);
    if (pull == null) return;
    _requests.removeWhere((_, r) {
      if (r.path != path || !identical(_folders[r.folder], f)) return false;
      final peer = _peers[r.dev];
      if (peer != null) peer.inflight--;
      return true;
    });
    _close(pull);
    try {
      File(pull.temp).deleteSync(); // contents nobody wants any more
    } on FileSystemException {
      // already gone
    }
  }

  // --- serving blocks -----------------------------------------------------------------

  void _onGet(String dev, Map<String, Object?> msg) {
    final id = _integer(msg['id']);
    final peer = _peers[dev];
    if (id == null || id < 0 || id > 0xFFFFFFFF || peer == null) return;
    void refuse(String code) =>
        _enqueue(dev, _Out.control({'t': 'sync.err', 'id': id, 'code': code}));
    final f = _folders[msg['folder'] is String ? msg['folder'] as String : ''];
    if (f == null || !f.state.config.grantOf(peer.key).sends) {
      return refuse('forbidden');
    }
    final path = msg['path'] is String ? msg['path'] as String : '';
    final l = f.state.local[path];
    if (!isValidSyncPath(path) ||
        l == null ||
        l.deleted ||
        l.dir ||
        l.skipped ||
        !f.state.participates(path) ||
        f.root.isEmpty) {
      return refuse('not_found');
    }
    final block = _integer(msg['block']) ?? -1;
    final hash = msg['hash'] is String ? hexToBytes(msg['hash'] as String) : Uint8List(0);
    if (block < 0 ||
        block >= l.blocks.length ||
        !bytesEqual(l.blocks[block], hash) ||
        _integer(msg['offset']) != block * l.blockSize ||
        _integer(msg['size']) != l.blockLength(block)) {
      return refuse('changed');
    }

    final abs = _absolute(f, path);
    final real = realPath(abs);
    if (_isLink(abs) || real.isEmpty || !_isWithin(real, f.root)) {
      return refuse('not_found');
    }
    Uint8List data;
    try {
      final file = File(abs).openSync();
      try {
        file.setPositionSync(block * l.blockSize);
        data = file.readSync(l.blockLength(block));
      } finally {
        file.closeSync();
      }
    } on FileSystemException {
      return refuse('io');
    }
    if (!bytesEqual(sha256Of(data), hash)) {
      f.rescanSoon = true; // the file changed since it was indexed
      return refuse('changed');
    }
    for (var at = 0; at < data.length; at += _frameSize) {
      final end = at + _frameSize < data.length ? at + _frameSize : data.length;
      _enqueue(dev, _Out.data(id, Uint8List.sublistView(data, at, end)));
    }
    peer.served.add(_now, data.length);
    peer.serving = path;
    peer.servingFolder = msg['folder'] as String;
    peer.servedAt = _now;
  }

  // --- messages -------------------------------------------------------------------------

  /// A control message: true if it was a sync.* message (handled or dropped).
  bool handleControl(String dev, Map<String, Object?> msg) {
    final t = msg['t'];
    if (t is! String || !t.startsWith('sync.')) return false;
    if (_disposed || !_peers.containsKey(dev)) {
      return true; // not a proven peer: nothing to say to it
    }
    switch (t) {
      case 'sync.offers':
        final offers = <Map<String, String>>[];
        final offered = <String>{};
        final list = msg['folders'];
        if (list is List) {
          for (final v in list) {
            if (v is! Map) continue;
            final id = v['id'] is String ? v['id'] as String : '';
            if (id.length != 32 || hexToBytes(id).length != 16) continue;
            offered.add(id);
            final label = v['label'] is String ? v['label'] as String : '';
            offers.add({
              'id': id,
              'label': label.length > 100 ? label.substring(0, 100) : label,
            });
          }
        }
        // A folder it no longer sends us: what we held of its index is no
        // longer ours to act on. Its next hello brings a full index.
        final peer = _peers[dev]!;
        _folders.forEach((id, f) {
          if (offered.contains(id) || !f.state.remotes.containsKey(peer.key)) return;
          f.state.remotes.remove(peer.key);
          peer.heard.remove(id);
          f.dirty = true;
          f.replan = true;
        });
        if (!_offers.isClosed) _offers.add(SyncOffers(peer.key, offers));
      case 'sync.hello':
        _onHello(dev, msg);
      case 'sync.index':
        _onIndex(dev, msg);
      case 'sync.get':
        _onGet(dev, msg);
      case 'sync.err':
        _onError(dev, msg);
    }
    return true;
  }

  // --- user actions ---------------------------------------------------------------------

  /// `choice`: "mine", "theirs" (with the holder's key) or "skip" (adds the
  /// path to .syncskip).
  void resolveConflict(String id, String path, String choice, String key) {
    final f = _folders[id];
    if (f == null) return;
    if (choice == 'mine') {
      f.state.keepMine(path);
    } else if (choice == 'theirs') {
      f.state.take(path, key);
    } else if (choice == 'skip') {
      try {
        File(joinPath(f.root, kSkipFile))
            .writeAsStringSync('${exactPattern(path)}\n', mode: FileMode.append);
      } on FileSystemException {
        // nothing added
      }
      f.rescanSoon = true;
    }
    f.blocked.remove(path);
    f.dirty = true;
    f.replan = true;
  }

  void rescan(String id) {
    final f = _folders[id];
    if (f == null) return;
    f.rescanSoon = true;
    f.blocked.clear();
  }

  // --- status -------------------------------------------------------------------------------

  /// A folder's state: {id, state (paused | waiting | missing | syncing |
  /// scanning | idle), reason (why it waits: wifi | charging), files, bytes,
  /// dirs, free, needFiles, needBytes, conflicts: [{path, involved,
  /// following, waiting, candidates: [{key, mine, size, mtime, deleted,
  /// dir}]}], blocked: {path: reason}, held: [{path, reason}], members:
  /// [{key, online, paused, toSendFiles, toSendBytes, toSendChanges,
  /// toReceiveFiles, toReceiveBytes, toReceiveChanges, current, sending,
  /// rate, sendRate, eta, skipped, lastSeen, lastInSync}], pendingDeletes:
  /// [path], pendingDeleteCount, transfers: [{path, size, done, key}]};
  /// empty for an unknown folder.
  Map<String, Object?> folderStatus(String id) {
    final f = _folders[id];
    if (f == null) return const {};
    var files = 0, bytes = 0, dirs = 0;
    for (final e in f.state.local.values) {
      if (e.deleted) continue;
      if (e.dir) {
        dirs++;
        continue;
      }
      files++;
      bytes += e.size;
    }
    var fetched = 0;
    final transfers = <Map<String, Object?>>[];
    f.pulls.forEach((path, p) {
      fetched += _doneOf(p.target, p.missing.length);
      transfers.add({
        'path': path,
        'size': p.target.size,
        'done': _doneOf(p.target, p.missing.length),
        'key': _sourceOf(id, path, p),
      });
    });
    final state = f.state.config.paused
        ? 'paused'
        : _suspended.isNotEmpty
            ? 'waiting'
            : f.root.isEmpty
                ? 'missing'
                : f.needFiles > 0
                    ? 'syncing'
                    : f.scanning
                        ? 'scanning'
                        : 'idle';
    final need = f.needBytes - fetched;
    return {
      'id': id,
      'state': state,
      'reason': _suspended,
      'files': files,
      'bytes': bytes,
      'dirs': dirs,
      'free': f.free,
      'needFiles': f.needFiles,
      'needBytes': need < 0 ? 0 : need,
      'conflicts': f.conflicts,
      'blocked': Map<String, String>.of(f.blocked),
      'held': f.held,
      'members': _memberStatus(id, f),
      'pendingDeletes': f.pendingDeletes.take(200).toList(),
      'pendingDeleteCount': f.pendingDeletes.length,
      'transfers': transfers,
    };
  }

  // The key of the peer a block of `path` was last asked of, else the first
  // connected holder.
  String _sourceOf(String folderId, String path, _Pull p) {
    for (final r in _requests.values.toList().reversed) {
      if (r.folder == folderId && r.path == path) {
        final peer = _peers[r.dev];
        if (peer != null) return peer.key;
      }
    }
    for (final source in p.sources) {
      if (_devOfKey.containsKey(source)) return source;
    }
    return '';
  }

  List<Map<String, Object?>> _memberStatus(String folderId, _Folder f) {
    final out = <Map<String, Object?>>[];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final now = _now;
    final keys = f.state.config.peers.keys.toList()..sort();
    for (final key in keys) {
      final g = f.state.config.grantOf(key);
      final peer = _peerOf(key);
      final need = f.needs[key] ?? _Need();
      final stats = f.state.peerStats[key];
      // What is on its way from it does not count as left.
      var receiveBytes = need.receiveBytes;
      for (final p in f.pulls.values) {
        if (p.sources.contains(key)) receiveBytes -= _doneOf(p.target, p.missing.length);
      }
      if (receiveBytes < 0) receiveBytes = 0;
      var current = '';
      var sending = false;
      if (peer != null) {
        final dev = _devOfKey[key];
        for (final r in _requests.values.toList().reversed) {
          if (r.dev == dev && r.folder == folderId) {
            current = r.path;
            break;
          }
        }
        if (current.isEmpty && peer.servingFolder == folderId && now - peer.servedAt < 3000) {
          current = peer.serving;
          sending = true;
        }
      }
      final rate = peer?.received.rate(now) ?? 0;
      final sendRate = peer?.served.rate(now) ?? 0;
      out.add({
        'key': key,
        'online': peer != null,
        'paused': g.paused,
        'toSendFiles': need.sendFiles,
        'toSendBytes': need.sendBytes,
        'toSendChanges': need.sendChanges,
        'toReceiveFiles': need.receiveFiles,
        'toReceiveBytes': receiveBytes,
        'toReceiveChanges': need.receiveChanges,
        'current': current,
        'sending': sending,
        'rate': rate,
        'sendRate': sendRate,
        'eta': rate > 0 && receiveBytes > 0 ? receiveBytes ~/ rate : -1,
        'skipped': need.skipped,
        'lastSeen': peer != null ? nowMs : (stats?.lastSeen ?? 0),
        'lastInSync': stats?.lastInSync ?? 0,
      });
    }
    return out;
  }

  void _emitStatus(String id) {
    final f = _folders[id];
    if (f == null) return;
    final status = folderStatus(id);
    final encoded = jsonEncode(status);
    if (encoded == f.lastStatus) return;
    // Progress alone need not reach the UI with every block.
    final state = '${status['state']}';
    if (state == f.lastState && _now - f.lastEmit < _emitEveryMs) return;
    f.lastEmit = _now;
    f.lastState = state;
    f.lastStatus = encoded;
    if (!_folderChanged.isClosed) _folderChanged.add(id);
  }

  // --- the folder as the user sees it ---------------------------------------------------

  /// Everything in the folder as sync sees it, sorted by path: [{path, name,
  /// dir, size, mtime, state, progress, detail, version: {memberId: n}}].
  /// `state`: synced | send (a change of ours some device has not got yet;
  /// `detail` how many) | receive (a change to fetch; `detail` "waiting" when
  /// no device online has it, "delete" for one to remove) | transferring
  /// (`progress` 0..1) | conflict | ignored (.syncignore) | skipped
  /// (.syncskip; for both, `detail` is the pattern) | held (not syncable
  /// here; `detail` the reason, see SyncFolder.heldReason()) | blocked
  /// (`detail` the reason, as in the "blocked:" events).
  List<Map<String, Object?>> files(String folderId) {
    final f = _folders[folderId];
    if (f == null) return const [];
    final s = f.state;
    final conflicts = {for (final c in f.conflicts) '${c['path']}'};
    final sendKeys = [
      for (final e in s.config.peers.entries)
        if (e.value.sends) e.key
    ];
    final sorted = {...f.leftOut.keys, ...s.allPaths()}.toList()..sort();

    final out = <Map<String, Object?>>[];
    for (final path in sorted) {
      final row = <String, Object?>{
        'path': path,
        'name': path.substring(path.lastIndexOf('/') + 1),
      };
      void fill(FileEntry e) {
        row['dir'] = e.dir;
        row['size'] = e.size;
        row['mtime'] = e.mtime;
        row['version'] = _versionMap(e.version);
      }

      var state = '', detail = '';
      var progress = -1.0;
      final local = s.local[path];
      final mine = local != null && !local.deleted;
      if (mine) fill(local);

      final left = f.leftOut[path];
      if (left != null) {
        row['dir'] = left.dir;
        row['size'] = left.size;
        row['mtime'] = 0;
        row['version'] ??= const <String, Object?>{};
        state = left.skip ? 'skipped' : 'ignored';
        detail = (left.skip ? s.skip : s.ignore).explain(path, left.dir).pattern;
      } else {
        var isDir = mine && local.dir;
        for (final r in s.remotes.values) {
          if (r.entries[path]?.dir == true) isDir = true;
        }
        final d = s.decide(path, _sinceOf);
        final pull = f.pulls[path];
        final blockedReason = f.blocked[path];
        if (!s.participates(path, isDir)) {
          if (!mine) {
            // Only other devices have it; here the rules leave it out.
            for (final r in s.remotes.values) {
              final e = r.entries[path];
              if (e != null && !e.deleted) {
                fill(e);
                break;
              }
            }
            if (!row.containsKey('dir')) continue;
          }
          final ignored = s.ignore.matches(path, isDir);
          state = ignored ? 'ignored' : 'skipped';
          detail = (ignored ? s.ignore : s.skip).explain(path, isDir).pattern;
        } else if (conflicts.contains(path) ||
            (d.kind == DecisionKind.conflict && !d.apply)) {
          if (!mine) {
            for (final c in d.candidates) {
              if (!c.entry.deleted) {
                fill(c.entry);
                break;
              }
            }
          }
          if (!row.containsKey('dir')) {
            fill(d.candidates.isEmpty ? FileEntry() : d.candidates.first.entry);
          }
          state = 'conflict';
        } else if (pull != null) {
          fill(pull.target);
          final online = pull.sources.any(_devOfKey.containsKey);
          if (online) {
            state = 'transferring';
            progress = pull.target.size > 0
                ? _doneOf(pull.target, pull.missing.length) / pull.target.size
                : 1.0;
          } else {
            state = 'receive';
            detail = 'waiting';
          }
        } else if (blockedReason != null) {
          if (!mine) fill(d.target);
          state = 'blocked';
          detail = blockedReason;
        } else if (mine && local.skipped) {
          state = 'held';
          detail = s.heldReason(path);
          if (detail.isEmpty) {
            state = 'skipped';
            detail = s.skip.explain(path, local.dir).pattern;
          }
        } else if (d.kind == DecisionKind.apply ||
            (d.kind == DecisionKind.conflict && d.apply)) {
          if (d.target.deleted) {
            if (!mine) continue;
            state = 'receive';
            detail = 'delete';
          } else {
            if (!mine) fill(d.target);
            state = 'receive';
            if (!d.sources.any(_devOfKey.containsKey)) detail = 'waiting';
          }
        } else if (mine) {
          var lacking = 0;
          for (final key in sendKeys) {
            if (_pendingFor(f, local, key)) lacking++;
          }
          state = lacking > 0 ? 'send' : 'synced';
          if (lacking > 0) detail = '$lacking';
        } else {
          continue; // a tombstone, or nothing to do
        }
      }
      row['state'] = state;
      row['detail'] = detail;
      row['progress'] = progress;
      out.add(row);
    }
    return out;
  }

  /// One path in depth: {path, dir, deleted, size, mtime, hash, version,
  /// skipped, state, detail, progress, holders: [{key, size, mtime, version,
  /// deleted, dir, skipped, hash}], kept: [{kept, path, time, size}]}.
  Map<String, Object?> fileInfo(String folderId, String path) {
    final f = _folders[folderId];
    if (f == null) return const {};
    final s = f.state;
    final out = <String, Object?>{'path': path};
    final l = s.local[path];
    if (l != null) {
      out['dir'] = l.dir;
      out['deleted'] = l.deleted;
      out['size'] = l.size;
      out['mtime'] = l.mtime;
      out['hash'] = bytesToHex(l.hash);
      out['version'] = _versionMap(l.version);
      out['skipped'] = l.skipped;
    }
    final holders = <Map<String, Object?>>[];
    final keys = s.remotes.keys.toList()..sort();
    for (final key in keys) {
      final e = s.remotes[key]!.entries[path];
      if (e == null) continue;
      holders.add({
        'key': key,
        'size': e.size,
        'mtime': e.mtime,
        'version': _versionMap(e.version),
        'deleted': e.deleted,
        'dir': e.dir,
        'skipped': e.skipped,
        'hash': bytesToHex(e.hash),
      });
    }
    out['holders'] = holders;
    out['kept'] = [
      for (final k in keptFiles(folderId))
        if (k['path'] == path) k
    ];
    for (final row in files(folderId)) {
      if (row['path'] != path) continue;
      out['state'] = row['state'];
      out['detail'] = row['detail'];
      out['progress'] = row['progress'];
      if (!out.containsKey('dir')) {
        out['dir'] = row['dir'];
        out['size'] = row['size'];
        out['mtime'] = row['mtime'];
        out['version'] = row['version'];
      }
      break;
    }
    return out;
  }

  // --- rules ------------------------------------------------------------------------------

  String _rulesPath(_Folder f, bool skipFile) =>
      joinPath(f.root, skipFile ? kSkipFile : kIgnoreFile);

  /// .syncignore (`skipFile` false) or .syncskip (true), as on disk.
  String rulesText(String folderId, bool skipFile) {
    final f = _folders[folderId];
    if (f == null || f.root.isEmpty) return '';
    return readSmallFile(_rulesPath(f, skipFile));
  }

  /// What `text` would do as the folder's rules: {problems: [{line,
  /// pattern}], matches: [{path, dir, line, pattern, negate, via}] for every
  /// known path a rule decides, stop: files synced now that would stop,
  /// resume: files left out now that would sync, probe: {path, dir, line,
  /// pattern, negate, via, excluded} for `probe`}.
  Map<String, Object?> previewRules(String folderId, bool skipFile, String text,
      {String probe = ''}) {
    final f = _folders[folderId];
    if (f == null) return const {};
    final s = f.state;
    final rules = IgnoreRules(text);
    final other = skipFile ? s.ignore : s.skip; // the file not being edited, as it is

    final dirs = <String, bool>{};
    final paths = <String>{...f.leftOut.keys};
    for (final e in s.local.values) {
      if (e.deleted) continue;
      paths.add(e.path);
      dirs[e.path] = e.dir;
    }
    for (final r in s.remotes.values) {
      for (final e in r.entries.values) {
        if (e.deleted) continue;
        paths.add(e.path);
        dirs.putIfAbsent(e.path, () => e.dir);
      }
    }
    f.leftOut.forEach((path, l) => dirs.putIfAbsent(path, () => l.dir));
    final sorted = paths.toList()..sort();

    final matches = <Map<String, Object?>>[];
    var stop = 0, resume = 0;
    for (final path in sorted) {
      final dir = dirs[path] ?? false;
      final m = rules.explain(path, dir);
      if (m.line > 0 && matches.length < _maxListed) {
        matches.add({'path': path, 'dir': dir, ...m.toJson()});
      }
      if (dir) continue;
      final wouldBeOut = rules.matches(path, false) || other.matches(path, false);
      final local = s.local[path];
      final syncedNow =
          local != null && !local.deleted && !local.skipped && s.participates(path);
      if (syncedNow && wouldBeOut) stop++;
      final left = f.leftOut[path];
      if (left != null && left.skip == skipFile && !wouldBeOut) resume++;
    }
    final out = <String, Object?>{
      'problems': [for (final p in rules.problems) p.toJson()],
      'matches': matches,
      'stop': stop,
      'resume': resume,
    };
    if (probe.isNotEmpty) {
      var p = probe.trim().replaceAll('\\', '/');
      while (p.startsWith('/')) {
        p = p.substring(1);
      }
      final dir = p.endsWith('/') || (dirs[p] ?? false);
      while (p.endsWith('/')) {
        p = p.substring(0, p.length - 1);
      }
      final m = rules.explain(p, dir);
      out['probe'] = {'path': p, 'dir': dir, ...m.toJson(), 'excluded': m.excluded};
    }
    return out;
  }

  /// Writes the rules file; the folder is scanned again with them.
  bool saveRules(String folderId, bool skipFile, String text) {
    final f = _folders[folderId];
    if (f == null || f.root.isEmpty) return false;
    final path = _rulesPath(f, skipFile);
    try {
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(text, flush: true);
      tmp.renameSync(path);
    } on FileSystemException {
      return false;
    }
    f.rescanSoon = true;
    f.replan = true;
    return true;
  }

  /// Adds a pattern matching exactly `path` ("Ignore everywhere" / "Skip on
  /// this device").
  bool addRule(String folderId, bool skipFile, String path) {
    final f = _folders[folderId];
    if (f == null || f.root.isEmpty || !isValidSyncPath(path)) return false;
    var text = rulesText(folderId, skipFile);
    if (text.isNotEmpty && !text.endsWith('\n')) text += '\n';
    text += '${exactPattern(path)}\n';
    return saveRules(folderId, skipFile, text);
  }

  // --- kept files -------------------------------------------------------------------------

  /// Files syncing set aside in .synctrash: [{kept (its path there), path
  /// (where it was), time, size}], newest first.
  List<Map<String, Object?>> keptFiles(String folderId) {
    final f = _folders[folderId];
    if (f == null || f.root.isEmpty) return const [];
    final root = joinPath(f.root, kKeptDir);
    if (!Directory(root).existsSync()) return const [];
    final out = <Map<String, Object?>>[];
    void walk(String dir, String rel) {
      List<FileSystemEntity> children;
      try {
        children = Directory(dir).listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final fe in children) {
        if (fe is Link) continue;
        final name = baseName(fe.path);
        final child = rel.isEmpty ? name : '$rel/$name';
        if (fe is Directory) {
          walk(fe.path, child);
          continue;
        }
        final FileStat st;
        try {
          st = fe.statSync();
        } on FileSystemException {
          continue;
        }
        var original = name;
        var when = st.modified.millisecondsSinceEpoch;
        final m = _keptName.firstMatch(name);
        if (m != null) {
          original = '${m.group(1)}${m.group(3) ?? ''}';
          when = _keptStamp(m.group(2)!) ?? when;
        }
        out.add({
          'kept': child,
          'path': rel.isEmpty ? original : '$rel/$original',
          'time': when,
          'size': st.size,
        });
      }
    }

    walk(root, '');
    out.sort((a, b) => (b['time'] as int).compareTo(a['time'] as int));
    return out;
  }

  /// Puts a kept file back where it was (beside what is there now, if
  /// anything), as a new change of ours.
  bool restoreKept(String folderId, String kept) {
    final f = _folders[folderId];
    if (f == null || f.root.isEmpty) return false;
    final keptRoot = joinPath(f.root, kKeptDir);
    final source = joinPath(keptRoot, kept);
    final real = realPath(source);
    if (real.isEmpty ||
        !_isWithin(real, keptRoot) ||
        FileSystemEntity.typeSync(source, followLinks: false) != FileSystemEntityType.file) {
      return false;
    }
    final name = baseName(source);
    final m = _keptName.firstMatch(name);
    final original = m == null ? name : '${m.group(1)}${m.group(3) ?? ''}';
    final slash = kept.lastIndexOf('/');
    final relDir = slash < 0 ? '' : kept.substring(0, slash);
    final relPath = relDir.isEmpty ? original : '$relDir/$original';
    if (!isValidSyncPath(relPath) || !_safeParent(f, relPath, true)) return false;
    final target = _uniquePath(_dirName(_absolute(f, relPath)), original);
    try {
      File(source).renameSync(target);
    } on FileSystemException {
      return false;
    }
    f.rescanSoon = true; // it comes back as a change of ours
    return true;
  }

  bool discardKept(String folderId, String kept) {
    final f = _folders[folderId];
    if (f == null || f.root.isEmpty) return false;
    final keptRoot = joinPath(f.root, kKeptDir);
    final source = joinPath(keptRoot, kept);
    final real = realPath(source);
    if (real.isEmpty ||
        !_isWithin(real, keptRoot) ||
        FileSystemEntity.typeSync(source, followLinks: false) != FileSystemEntityType.file) {
      return false;
    }
    try {
      File(source).deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  // --- held deletes, transfers --------------------------------------------------------------

  /// Deletes held back by the large-delete guard (`pendingDeletes`): apply
  /// them, or keep the files, which makes them changes of ours that the
  /// other devices take back.
  void confirmDeletes(String folderId, bool apply) {
    final f = _folders[folderId];
    if (f == null || f.pendingDeletes.isEmpty) return;
    if (apply) {
      f.approvedDeletes.addAll(f.pendingDeletes);
    } else {
      for (final path in f.pendingDeletes) {
        f.state.keepMine(path);
      }
    }
    f.pendingDeletes = [];
    f.dirty = true;
    f.replan = true;
  }

  /// Transfers across every folder: [{folder, path, size, done, key,
  /// active}], active ones first, then what waits its turn.
  List<Map<String, Object?>> transfers() {
    final out = <Map<String, Object?>>[];
    final queued = <Map<String, Object?>>[];
    _folders.forEach((id, f) {
      f.pulls.forEach((path, p) {
        out.add({
          'folder': id,
          'path': path,
          'size': p.target.size,
          'done': _doneOf(p.target, p.missing.length),
          'key': _sourceOf(id, path, p),
          'active': true,
        });
      });
      for (final path in f.queued) {
        var size = 0;
        for (final r in f.state.remotes.values) {
          final e = r.entries[path];
          if (e != null && !e.deleted) size = e.size;
        }
        queued.add({
          'folder': id,
          'path': path,
          'size': size,
          'done': 0,
          'key': '',
          'active': false,
        });
      }
    });
    return out..addAll(queued);
  }

  /// Bytes per second fetched from every peer, over the last seconds.
  int receiveRate() {
    var rate = 0;
    for (final p in _peers.values) {
      rate += p.received.rate(_now);
    }
    return rate;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _workTimer?.cancel();
    _pumpTimer?.cancel();
    for (final f in _folders.values) {
      for (final p in f.pulls.values) {
        _close(p); // the part file stays, to resume
      }
      if (f.dirty) f.state.save();
    }
    await _offers.close();
    await _folderChanged.close();
    await _events.close();
  }
}
