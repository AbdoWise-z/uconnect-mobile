// The sync engine on its own isolate, as the desktop runs it on its own
// thread. Planning a large folder, hashing blocks, encoding the state file
// and listing files all take time that grows with the folder; done on the UI
// isolate they froze the app. SyncClient has SyncService's surface: the
// same commands, status answered from the last snapshot the worker sent,
// and the listings as futures.
//
// Messages are plain lists, `[op, ...args]`. Blocks cross as
// TransferableTypedData, which moves the bytes rather than copying them.

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'sync_folder.dart';
import 'sync_service.dart';

/// The knobs on SyncService that tests shorten; null leaves one as it is.
class SyncSettings {
  const SyncSettings({
    this.scanIntervalMs,
    this.stableAfterMs,
    this.keepDays,
    this.guardMin,
    this.guardMany,
    this.guardShare,
  });
  final int? scanIntervalMs;
  final int? stableAfterMs;
  final int? keepDays;
  final int? guardMin;
  final int? guardMany;
  final double? guardShare;

  Map<String, Object?> toMap() => {
        'scanIntervalMs': scanIntervalMs,
        'stableAfterMs': stableAfterMs,
        'keepDays': keepDays,
        'guardMin': guardMin,
        'guardMany': guardMany,
        'guardShare': guardShare,
      };
}

class _WorkerArgs {
  _WorkerArgs(this.toMain, this.myKeyHex, this.stateDir);
  final SendPort toMain;
  final String myKeyHex;
  final String stateDir;
}

// --- the worker isolate -------------------------------------------------------------

void _workerMain(_WorkerArgs a) {
  final port = ReceivePort();
  final toMain = a.toMain;
  // What the main isolate knows about each connected device, mirrored here.
  final keys = <String, String>{};
  final since = <String, int>{};
  final freeAsked = <int, Completer<int>>{};
  var nextFree = 1;

  final svc = SyncService(
    sendControl: (dev, msg) {
      toMain.send(['ctl', dev, msg]);
      return true; // the main isolate holds it until the link takes it
    },
    sendData: (dev, id, bytes) {
      toMain.send(['data', dev, id, TransferableTypedData.fromList([bytes])]);
      return true;
    },
    peerKey: (dev) => keys[dev],
    connectedSince: (dev) => since[dev] ?? -1,
    myKeyHex: a.myKeyHex,
    stateDir: a.stateDir,
    freeSpace: (path) {
      final id = nextFree++;
      final c = Completer<int>();
      freeAsked[id] = c;
      toMain.send(['free', id, path]);
      return c.future;
    },
  );
  svc.offers.listen((o) => toMain.send(['offers', o.peerKey, o.folders]));
  svc.events.listen((e) =>
      toMain.send(['event', e.folderId, e.path, e.kind, e.time.millisecondsSinceEpoch]));
  svc.folderChanged.listen((id) =>
      toMain.send(['status', id, svc.folderStatus(id), svc.transfers(), svc.receiveRate()]));

  Object? answer(String what, List<Object?> m) {
    switch (what) {
      case 'files':
        return svc.files(m[0] as String);
      case 'fileInfo':
        return svc.fileInfo(m[0] as String, m[1] as String);
      case 'rulesText':
        return svc.rulesText(m[0] as String, m[1] as bool);
      case 'previewRules':
        return svc.previewRules(m[0] as String, m[1] as bool, m[2] as String,
            probe: m[3] as String);
      case 'saveRules':
        return svc.saveRules(m[0] as String, m[1] as bool, m[2] as String);
      case 'addRule':
        return svc.addRule(m[0] as String, m[1] as bool, m[2] as String);
      case 'keptFiles':
        return svc.keptFiles(m[0] as String);
      case 'restoreKept':
        return svc.restoreKept(m[0] as String, m[1] as String);
      case 'discardKept':
        return svc.discardKept(m[0] as String, m[1] as String);
      case 'status':
        return svc.folderStatus(m[0] as String);
    }
    throw ArgumentError('unknown request $what');
  }

  late final StreamSubscription<Object?> sub;
  sub = port.listen((raw) async {
    final m = raw as List<Object?>;
    final op = m[0] as String;
    try {
      switch (op) {
        case 'req':
          final id = m[1] as int;
          Object? result;
          String error = '';
          try {
            result = answer(m[2] as String, m.sublist(3));
          } on Object catch (e) {
            error = '$e';
          }
          toMain.send(['rep', id, result, error]);
        case 'setFolders':
          svc.setFolders((m[1] as List).cast<FolderConfig>());
        case 'peerUp':
          final dev = m[1] as String;
          final key = m[2] as String?;
          if (key == null) {
            keys.remove(dev);
            since.remove(dev);
          } else {
            keys[dev] = key;
            since[dev] = m[3] as int;
          }
          svc.peerUp(dev);
        case 'peerGone':
          final dev = m[1] as String;
          keys.remove(dev);
          since.remove(dev);
          svc.peerGone(dev);
        case 'control':
          svc.handleControl(m[1] as String, (m[2] as Map).cast<String, Object?>());
        case 'frame':
          svc.handleData(m[1] as String, m[2] as int,
              (m[3] as TransferableTypedData).materialize().asUint8List());
        case 'suspend':
          svc.suspended = m[1] as String;
        case 'settings':
          final s = (m[1] as Map).cast<String, Object?>();
          if (s['scanIntervalMs'] != null) svc.scanIntervalMs = s['scanIntervalMs'] as int;
          if (s['stableAfterMs'] != null) svc.stableAfterMs = s['stableAfterMs'] as int;
          if (s['keepDays'] != null) svc.keepDays = s['keepDays'] as int;
          if (s['guardMin'] != null) svc.guardMin = s['guardMin'] as int;
          if (s['guardMany'] != null) svc.guardMany = s['guardMany'] as int;
          if (s['guardShare'] != null) svc.guardShare = s['guardShare'] as double;
        case 'resolve':
          svc.resolveConflict(m[1] as String, m[2] as String, m[3] as String, m[4] as String);
        case 'rescan':
          svc.rescan(m[1] as String);
        case 'confirmDeletes':
          svc.confirmDeletes(m[1] as String, m[2] as bool);
        case 'free':
          freeAsked.remove(m[1] as int)?.complete(m[2] as int);
        case 'stop':
          await sub.cancel();
          await svc.dispose();
          toMain.send(['stopped']);
          port.close();
      }
    } on Object catch (e, st) {
      toMain.send(['error', '$op: $e\n$st']);
    }
  });
  toMain.send(['ready', port.sendPort]);
}

// --- the main-isolate side ----------------------------------------------------------

class _Pending {
  _Pending(this.send);
  final bool Function() send;
}

/// SyncService, run on another isolate. Construct it, then [start]; commands
/// sent before the worker is up wait for it.
class SyncClient {
  SyncClient({
    required bool Function(String dev, Map<String, Object?> msg) sendControl,
    required bool Function(String dev, int requestId, Uint8List bytes) sendData,
    required String? Function(String dev) peerKey,
    required int Function(String dev) connectedSince,
    required String myKeyHex,
    required String stateDir,
    Future<int> Function(String path)? freeSpace,
    void Function(String message)? onError,
  })  : _sendControl = sendControl,
        _sendData = sendData,
        _peerKey = peerKey,
        _since = connectedSince,
        _myKeyHex = myKeyHex,
        _stateDir = stateDir,
        _freeSpace = freeSpace,
        _onError = onError;

  final bool Function(String, Map<String, Object?>) _sendControl;
  final bool Function(String, int, Uint8List) _sendData;
  final String? Function(String) _peerKey;
  final int Function(String) _since;
  final String _myKeyHex;
  final String _stateDir;
  final Future<int> Function(String)? _freeSpace;
  final void Function(String)? _onError;

  Isolate? _isolate;
  SendPort? _port;
  ReceivePort? _fromWorker;
  final _queued = <List<Object?>>[]; // sent once the worker is ready
  final _replies = <int, Completer<Object?>>{};
  int _nextRequest = 1;
  bool _disposed = false;
  Completer<void>? _stopped;

  final _offers = StreamController<SyncOffers>.broadcast();
  final _folderChanged = StreamController<String>.broadcast();
  final _events = StreamController<SyncEvent>.broadcast();

  Stream<SyncOffers> get offers => _offers.stream;
  Stream<String> get folderChanged => _folderChanged.stream;
  Stream<SyncEvent> get events => _events.stream;

  // The last snapshot of each folder, and of the transfers across them.
  final _status = <String, Map<String, Object?>>{};
  List<Map<String, Object?>> _transfers = const [];
  int _rate = 0;

  // Outgoing messages the link has not taken yet, in order per device.
  final _outgoing = <String, Queue<_Pending>>{};
  Timer? _retry;

  String _suspended = '';
  int _keepDays = 30;

  /// Spawns the worker. Safe to call once; commands queue until it is up.
  Future<void> start() async {
    if (_isolate != null || _disposed) return;
    final from = ReceivePort();
    _fromWorker = from;
    from.listen(_onMessage);
    _isolate = await Isolate.spawn(
        _workerMain, _WorkerArgs(from.sendPort, _myKeyHex, _stateDir),
        debugName: 'sync', errorsAreFatal: false);
  }

  void _onMessage(Object? raw) {
    final m = raw as List<Object?>;
    switch (m[0] as String) {
      case 'ready':
        _port = m[1] as SendPort;
        for (final q in _queued) {
          _port!.send(q);
        }
        _queued.clear();
      case 'ctl':
        _relay(m[1] as String, () => _sendControl(m[1] as String, (m[2] as Map).cast<String, Object?>()));
      case 'data':
        final bytes = (m[3] as TransferableTypedData).materialize().asUint8List();
        _relay(m[1] as String, () => _sendData(m[1] as String, m[2] as int, bytes));
      case 'free':
        final id = m[1] as int;
        final ask = _freeSpace;
        if (ask == null) {
          _send(['free', id, -1]);
        } else {
          ask(m[2] as String).then((v) => _send(['free', id, v]),
              onError: (Object _) => _send(['free', id, -1]));
        }
      case 'offers':
        if (!_offers.isClosed) {
          _offers.add(SyncOffers(m[1] as String,
              (m[2] as List).map((e) => (e as Map).cast<String, String>()).toList()));
        }
      case 'event':
        if (!_events.isClosed) {
          _events.add(SyncEvent(m[1] as String, m[2] as String, m[3] as String,
              time: DateTime.fromMillisecondsSinceEpoch(m[4] as int)));
        }
      case 'status':
        final id = m[1] as String;
        _status[id] = (m[2] as Map).cast<String, Object?>();
        _transfers = (m[3] as List).map((e) => (e as Map).cast<String, Object?>()).toList();
        _rate = m[4] as int;
        if (!_folderChanged.isClosed) _folderChanged.add(id);
      case 'rep':
        final c = _replies.remove(m[1] as int);
        if (c == null) return;
        final error = m[3] as String;
        if (error.isEmpty) {
          c.complete(m[2]);
        } else {
          c.completeError(StateError(error));
        }
      case 'error':
        _onError?.call(m[1] as String);
      case 'stopped':
        _stopped?.complete();
    }
  }

  void _send(List<Object?> m) {
    if (_disposed) return;
    final p = _port;
    if (p == null) {
      _queued.add(m);
    } else {
      p.send(m);
    }
  }

  Future<T> _ask<T>(String what, List<Object?> args) {
    if (_disposed) return Future.error(StateError('sync is stopped'));
    final id = _nextRequest++;
    final c = Completer<Object?>();
    _replies[id] = c;
    _send(['req', id, what, ...args]);
    return c.future.then((v) => v as T);
  }

  // The link takes a message or says its queue is full; what it does not take
  // waits here, in order per device, and is tried again shortly.
  void _relay(String dev, bool Function() send) {
    final q = _outgoing[dev];
    if (q == null || q.isEmpty) {
      if (send()) return;
    }
    (_outgoing[dev] ??= Queue()).add(_Pending(send));
    _retry ??= Timer(const Duration(milliseconds: 10), _flush);
  }

  void _flush() {
    _retry = null;
    if (_disposed) return;
    var pending = false;
    for (final q in _outgoing.values) {
      while (q.isNotEmpty && q.first.send()) {
        q.removeFirst();
      }
      pending = pending || q.isNotEmpty;
    }
    _outgoing.removeWhere((_, q) => q.isEmpty);
    if (pending) _retry = Timer(const Duration(milliseconds: 10), _flush);
  }

  // --- SyncService's surface -------------------------------------------------------

  String get suspended => _suspended;
  set suspended(String reason) {
    if (_suspended == reason) return;
    _suspended = reason;
    _send(['suspend', reason]);
  }

  int get keepDays => _keepDays;

  void configure(SyncSettings s) {
    if (s.keepDays != null) _keepDays = s.keepDays!;
    _send(['settings', s.toMap()]);
  }

  void setFolders(List<FolderConfig> configs) {
    final wanted = {for (final c in configs) c.id};
    _status.removeWhere((id, _) => !wanted.contains(id));
    _send(['setFolders', List<FolderConfig>.of(configs)]);
  }

  /// A peer connected, proved who it is, or its grants changed: its key and
  /// connection time are read now and travel with the message.
  void peerUp(String dev) {
    final key = _peerKey(dev);
    _send(['peerUp', dev, key, key == null ? -1 : _since(dev)]);
  }

  void peerGone(String dev) {
    _outgoing.remove(dev);
    _send(['peerGone', dev]);
  }

  /// True if it was a sync.* message (handed to the worker, or dropped).
  bool handleControl(String dev, Map<String, Object?> msg) {
    final t = msg['t'];
    if (t is! String || !t.startsWith('sync.')) return false;
    _send(['control', dev, msg]);
    return true;
  }

  void handleData(String dev, int requestId, Uint8List bytes) {
    _send(['frame', dev, requestId, TransferableTypedData.fromList([bytes])]);
  }

  void resolveConflict(String id, String path, String choice, String key) =>
      _send(['resolve', id, path, choice, key]);

  void rescan(String id) => _send(['rescan', id]);

  void confirmDeletes(String folderId, bool apply) =>
      _send(['confirmDeletes', folderId, apply]);

  /// The folder's state as last reported; empty before the first report.
  Map<String, Object?> folderStatus(String id) => _status[id] ?? const {};

  /// The same, asked of the worker now.
  Future<Map<String, Object?>> refreshStatus(String id) async {
    final st = (await _ask<Map>('status', [id])).cast<String, Object?>();
    if (st.isNotEmpty) _status[id] = st;
    return st;
  }

  List<Map<String, Object?>> transfers() => _transfers;
  int receiveRate() => _rate;

  Future<List<Map<String, Object?>>> files(String folderId) async =>
      (await _ask<List>('files', [folderId]))
          .map((e) => (e as Map).cast<String, Object?>())
          .toList();

  Future<Map<String, Object?>> fileInfo(String folderId, String path) async =>
      (await _ask<Map>('fileInfo', [folderId, path])).cast<String, Object?>();

  Future<String> rulesText(String folderId, bool skipFile) =>
      _ask<String>('rulesText', [folderId, skipFile]);

  Future<Map<String, Object?>> previewRules(String folderId, bool skipFile, String text,
          {String probe = ''}) async =>
      (await _ask<Map>('previewRules', [folderId, skipFile, text, probe]))
          .cast<String, Object?>();

  Future<bool> saveRules(String folderId, bool skipFile, String text) =>
      _ask<bool>('saveRules', [folderId, skipFile, text]);

  Future<bool> addRule(String folderId, bool skipFile, String path) =>
      _ask<bool>('addRule', [folderId, skipFile, path]);

  Future<List<Map<String, Object?>>> keptFiles(String folderId) async =>
      (await _ask<List>('keptFiles', [folderId]))
          .map((e) => (e as Map).cast<String, Object?>())
          .toList();

  Future<bool> restoreKept(String folderId, String kept) =>
      _ask<bool>('restoreKept', [folderId, kept]);

  Future<bool> discardKept(String folderId, String kept) =>
      _ask<bool>('discardKept', [folderId, kept]);

  /// Stops the worker: it saves what it has and closes its files first.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    _outgoing.clear();
    for (final c in _replies.values) {
      c.completeError(StateError('sync is stopped'));
    }
    _replies.clear();
    if (_port != null) {
      final stopped = _stopped = Completer<void>();
      _port!.send(['stop']);
      await stopped.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _fromWorker?.close();
    await _offers.close();
    await _folderChanged.close();
    await _events.close();
  }
}
