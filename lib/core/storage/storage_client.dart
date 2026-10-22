// The requester side of the storage protocol (docs/protocol.md section 5):
// listing, download with resume and SHA-256 verification, upload, the change
// operations, and folder watches. Limits and timeouts follow the protocol:
// at most 4 downloads and 4 uploads requested per peer at once, 20 s for an
// unanswered request, 30 s for a transfer that stops making progress, with
// fs.progress extending an operation's deadline.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../session.dart';
import '../wire.dart';

const int kFrameMax = 256 * 1024;
const Duration kRequestTimeout = Duration(seconds: 20);
const Duration kStallTimeout = Duration(seconds: 30);

class FsEntry {
  FsEntry(this.name, this.dir, this.size, this.mtime, {this.readOnly});
  final String name;
  final bool dir;
  final int size;
  final int mtime; // ms since epoch
  final bool? readOnly; // only on entries at "/"

  static FsEntry? fromJson(Object? v) {
    if (v is! Map) return null;
    final name = v['name'];
    if (name is! String) return null;
    return FsEntry(
      name,
      v['dir'] == true,
      v['size'] is num ? (v['size'] as num).toInt() : 0,
      v['mtime'] is num ? (v['mtime'] as num).toInt() : 0,
      readOnly: v['readOnly'] is bool ? v['readOnly'] as bool : null,
    );
  }
}

class FsListing {
  FsListing(this.path, this.entries, this.readOnly);
  final String path;
  final List<FsEntry> entries;
  final bool readOnly;
}

class FsException implements Exception {
  FsException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}

enum TransferKind { download, upload }

enum TransferState { queued, running, done, failed, cancelled }

class Transfer {
  Transfer(this.id, this.dev, this.kind, this.remotePath, this.localPath);
  final int id;
  final String dev;
  final TransferKind kind;
  final String remotePath;
  String localPath;
  int total = 0;
  int done = 0;
  TransferState state = TransferState.queued;
  String error = '';
}

/// Cleans a remote name before it becomes a local file name (5.11).
String safeLocalName(String name) {
  var out = name.replaceAll(RegExp(r'[\x00-\x1f/\\:*?"<>|]'), '_');
  out = out.trim();
  while (out.endsWith('.') || out.endsWith(' ')) {
    out = out.substring(0, out.length - 1);
  }
  if (out.isEmpty) out = 'download';
  final upper = out.toUpperCase();
  final base = upper.contains('.') ? upper.substring(0, upper.indexOf('.')) : upper;
  const devices = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  if (devices.contains(base)) out = '_$out';
  if (out.length > 200) out = out.substring(0, 200);
  return out;
}

/// A name is sendable as an upload's `name` only if a safe-name filter would
/// leave it unchanged (5.6).
bool isCleanUploadName(String name) => name.isNotEmpty && safeLocalName(name) == name;

class _PendingReply {
  _PendingReply(this.completer) {
    touch();
  }
  final Completer<Map<String, Object?>> completer;
  Timer? timer;
  void touch([Duration timeout = kRequestTimeout]) {
    timer?.cancel();
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(FsException('timeout', 'No answer from the device.'));
      }
    });
  }

  void cancel() => timer?.cancel();
}

class _Download {
  _Download(this.transfer, this.sink, this.file);
  final Transfer transfer;
  IOSink sink;
  final File file;
  int received = 0; // bytes written locally, including resumed offset
  int expectedSize = 0; // the fs.read.r size
  int offset = 0; // granted resume offset
  Timer? stall;
  Completer<void> doneSignal = Completer<void>();
  bool started = false;
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

class _Upload {
  _Upload(this.transfer, this.file, this.folder, this.name, this.replace);
  final Transfer transfer;
  final File file;
  final String folder;
  final String name;
  final bool replace;
  bool ready = false;
  bool cancelled = false;
  Completer<Map<String, Object?>> result = Completer<Map<String, Object?>>();
  Timer? timer;
}

class StorageClient {
  StorageClient(this.session) {
    session.addControlHandler(_onControl);
    session.setFrameHandler(MessageKind.data, _onDataFrame);
    session.addPeerStateHandler(_onPeerState);
  }

  final Session session;
  int _nextId = 1;

  final _replies = <int, _PendingReply>{}; // list + ops
  final _downloads = <int, _Download>{};
  final _uploads = <int, _Upload>{};
  final _watches = <int, void Function(String path)>{};
  final _watchDevs = <int, String>{};

  final transfers = <Transfer>[];
  final _transfersChanged = StreamController<void>.broadcast();
  Stream<void> get transfersChanged => _transfersChanged.stream;

  // Downloads and uploads a peer is currently asked for, to honor the
  // 4-in-flight limit; the rest wait in these queues.
  final _downloadQueue = <Future<void> Function()>[];
  final _uploadQueue = <Future<void> Function()>[];
  final _activeDownloads = <String, int>{};
  final _activeUploads = <String, int>{};

  int _takeId() => _nextId++;

  void _notifyTransfers() {
    if (!_transfersChanged.isClosed) _transfersChanged.add(null);
  }

  void _onPeerState(String dev, int state) {
    // On close (5) or fail (4), everything pending towards that peer dies;
    // plain replies are reaped by their own timeouts.
    if (state != 4 && state != 5) return;
    for (final d in _downloads.values.toList()) {
      if (d.transfer.dev == dev && d.transfer.state == TransferState.running) {
        _failDownload(d, 'disconnected', 'The device disconnected.');
      }
    }
    for (final u in _uploads.values.toList()) {
      if (u.transfer.dev == dev && !u.result.isCompleted) {
        u.result.completeError(FsException('disconnected', 'The device disconnected.'));
      }
    }
  }

  // --- control dispatch ----------------------------------------------------

  bool _onControl(String dev, Map<String, Object?> msg) {
    final t = msg['t'];
    if (t is! String || !t.startsWith('fs.')) return false;
    // Only the replies to our own requests are ours; fs.list, fs.read and the
    // other REQUESTS fall through to the offerer, and unknown types to no one.
    final id = msg['id'] is num ? (msg['id'] as num).toInt() : null;
    switch (t) {
      case 'fs.list.r':
      case 'fs.done':
        if (id != null) _completeReply(id, msg);
      case 'fs.err':
        if (id != null) _failById(id, msg);
      case 'fs.progress':
        if (id != null) _replies[id]?.touch(kStallTimeout);
      case 'fs.read.r':
        if (id != null) _onReadReply(id, msg);
      case 'fs.read.end':
        if (id != null) _onReadEnd(id, msg);
      case 'fs.write.r':
        if (id != null) _onWriteReady(id);
      case 'fs.write.done':
        if (id != null) _onWriteDone(id, msg);
      case 'fs.write.err':
        if (id != null) _onWriteErr(id, msg);
      case 'fs.changed':
        if (id != null) {
          final cb = _watches[id];
          final path = msg['path'];
          if (cb != null && path is String) cb(path);
        }
      default:
        return false;
    }
    return true;
  }

  void _completeReply(int id, Map<String, Object?> msg) {
    final p = _replies.remove(id);
    p?.cancel();
    if (p != null && !p.completer.isCompleted) p.completer.complete(msg);
  }

  void _failById(int id, Map<String, Object?> msg) {
    final code = msg['code'] is String ? msg['code'] as String : 'error';
    final text = msg['error'] is String ? msg['error'] as String : '';
    final p = _replies.remove(id);
    if (p != null) {
      p.cancel();
      if (!p.completer.isCompleted) {
        p.completer.completeError(FsException(code, text));
      }
      return;
    }
    final d = _downloads[id];
    if (d != null) {
      _failDownload(d, code, text);
      return;
    }
    final u = _uploads[id];
    if (u != null && !u.result.isCompleted) {
      u.result.completeError(FsException(code, text));
    }
  }

  Future<Map<String, Object?>> _request(
      String dev, Map<String, Object?> message) {
    final id = message['id'] as int;
    final pending = _PendingReply(Completer<Map<String, Object?>>());
    _replies[id] = pending;
    if (!session.sendControl(dev, message)) {
      _replies.remove(id);
      pending.cancel();
      return Future.error(
          FsException('send', 'The message could not be queued.'));
    }
    return pending.completer.future.whenComplete(() {
      _replies.remove(id);
      pending.cancel();
    });
  }

  // --- listing -------------------------------------------------------------

  Future<FsListing> list(String dev, String path, {int offset = 0}) async {
    const pageLimit = 20000; // requesters SHOULD stop at 20 000 entries
    final entries = <FsEntry>[];
    var readOnly = false;
    var at = offset;
    while (true) {
      final id = _takeId();
      final reply = await _request(
          dev, {'t': 'fs.list', 'id': id, 'path': path, 'offset': at});
      readOnly = reply['readOnly'] == true;
      final total = reply['total'] is num ? (reply['total'] as num).toInt() : 0;
      final page = <FsEntry>[
        if (reply['entries'] is List)
          for (final e in reply['entries'] as List)
            if (FsEntry.fromJson(e) != null) FsEntry.fromJson(e)!
      ];
      entries.addAll(page);
      at += page.length;
      if (page.isEmpty || entries.length >= total || entries.length >= pageLimit) {
        break;
      }
    }
    return FsListing(path, entries, readOnly);
  }

  // --- download ------------------------------------------------------------

  /// Downloads `remotePath` from `dev` into `localPath`, resuming a partial
  /// file left by an earlier failed attempt. The returned transfer updates as
  /// frames arrive (listen on [transfersChanged]).
  Transfer download(String dev, String remotePath, String localPath) {
    final id = _takeId();
    final transfer =
        Transfer(id, dev, TransferKind.download, remotePath, localPath);
    transfers.add(transfer);
    _notifyTransfers();
    _downloadQueue.add(() => _runDownload(transfer));
    _pumpQueue(dev);
    return transfer;
  }

  void _pumpQueue(String dev) {
    while ((_activeDownloads[dev] ?? 0) < 4 && _downloadQueue.isNotEmpty) {
      final job = _downloadQueue.removeAt(0);
      _activeDownloads[dev] = (_activeDownloads[dev] ?? 0) + 1;
      unawaited(job().whenComplete(() {
        _activeDownloads[dev] = (_activeDownloads[dev] ?? 1) - 1;
        _pumpQueue(dev);
      }));
    }
    while ((_activeUploads[dev] ?? 0) < 4 && _uploadQueue.isNotEmpty) {
      final job = _uploadQueue.removeAt(0);
      _activeUploads[dev] = (_activeUploads[dev] ?? 0) + 1;
      unawaited(job().whenComplete(() {
        _activeUploads[dev] = (_activeUploads[dev] ?? 1) - 1;
        _pumpQueue(dev);
      }));
    }
  }

  Future<void> _runDownload(Transfer transfer) async {
    if (transfer.state == TransferState.cancelled) return;
    final file = File(transfer.localPath);
    final part = File('${transfer.localPath}.ucpart');
    var offset = 0;
    if (await part.exists()) offset = await part.length();
    transfer.state = TransferState.running;
    transfer.done = offset;
    _notifyTransfers();

    final d = _Download(
        transfer, part.openWrite(mode: FileMode.append), part)
      ..received = offset;
    _downloads[transfer.id] = d;
    d.stall = Timer(kRequestTimeout, () {
      _failDownload(d, 'timeout', 'No answer from the device.');
    });
    if (!session.sendControl(transfer.dev, {
      't': 'fs.read',
      'id': transfer.id,
      'path': transfer.remotePath,
      'offset': offset,
    })) {
      _failDownload(d, 'send', 'The request could not be queued.');
      return;
    }
    try {
      await d.doneSignal.future;
      // Verified in _onReadEnd; move the part file into place.
      await d.sink.close();
      if (await file.exists()) await file.delete();
      await d.file.rename(file.path);
      transfer.state = TransferState.done;
    } on FsException catch (e) {
      transfer.state = transfer.state == TransferState.cancelled
          ? TransferState.cancelled
          : TransferState.failed;
      transfer.error = e.toString();
    } finally {
      _downloads.remove(transfer.id);
      _notifyTransfers();
    }
  }

  void _onReadReply(int id, Map<String, Object?> msg) {
    final d = _downloads[id];
    if (d == null) return;
    d.started = true;
    d.expectedSize = msg['size'] is num ? (msg['size'] as num).toInt() : 0;
    final granted = msg['offset'] is num ? (msg['offset'] as num).toInt() : 0;
    d.offset = granted;
    d.transfer.total = d.expectedSize;
    if (granted != d.received) {
      // The offerer starts over (usually offset 0): drop what we kept.
      unawaited(() async {
        await d.sink.close();
        d.sink = d.file.openWrite(mode: FileMode.write);
        d.received = granted;
        d.transfer.done = granted;
      }());
    }
    _armStall(d);
    _notifyTransfers();
  }

  void _armStall(_Download d) {
    d.stall?.cancel();
    d.stall = Timer(kStallTimeout, () {
      _failDownload(d, 'stalled', 'The transfer stopped making progress.');
    });
  }

  void _onDataFrame(String dev, int id, Uint8List bytes) {
    final d = _downloads[id];
    if (d == null || d.transfer.dev != dev) return;
    d.sink.add(bytes);
    d.received += bytes.length;
    d.transfer.done = d.received;
    _armStall(d);
    _notifyTransfers();
  }

  Future<void> _onReadEnd(int id, Map<String, Object?> msg) async {
    final d = _downloads[id];
    if (d == null) return;
    d.stall?.cancel();
    final sent = msg['sent'] is num ? (msg['sent'] as num).toInt() : -1;
    final sha = msg['sha256'] is String ? msg['sha256'] as String : null;
    await d.sink.flush();
    if (sent != d.received) {
      _failDownload(d, 'corrupt', 'The transfer ended short.');
      return;
    }
    if (sha != null) {
      // Hash the whole local file: resumed bytes included.
      final digest = await _sha256OfFile(d.file);
      if (digest != sha.toLowerCase()) {
        try {
          await d.sink.close();
          await d.file.delete();
        } on FileSystemException {
          // best effort
        }
        _failDownload(d, 'corrupt', 'The file did not match its checksum.');
        return;
      }
    }
    if (!d.doneSignal.isCompleted) d.doneSignal.complete();
  }

  void _failDownload(_Download d, String code, String text) {
    d.stall?.cancel();
    if (!d.doneSignal.isCompleted) {
      d.doneSignal.completeError(FsException(code, text));
    }
  }

  void cancelDownload(Transfer t) {
    final d = _downloads[t.id];
    t.state = TransferState.cancelled;
    if (d != null) {
      session.sendControl(t.dev, {'t': 'fs.cancel', 'id': t.id});
      _failDownload(d, 'cancelled', 'Cancelled.');
    }
    _notifyTransfers();
  }

  // --- upload --------------------------------------------------------------

  Transfer upload(String dev, String localPath, String remoteFolder,
      {String? name, bool replace = false}) {
    final id = _takeId();
    final cleanName = name ?? safeLocalName(localPath.split(RegExp(r'[/\\]')).last);
    final transfer = Transfer(id, dev, TransferKind.upload,
        '$remoteFolder/$cleanName', localPath);
    transfers.add(transfer);
    _notifyTransfers();
    _uploadQueue.add(() => _runUpload(transfer, remoteFolder, cleanName, replace));
    _pumpQueue(dev);
    return transfer;
  }

  Future<void> _runUpload(
      Transfer transfer, String folder, String name, bool replace) async {
    if (transfer.state == TransferState.cancelled) return;
    final file = File(transfer.localPath);
    final size = await file.length();
    transfer.total = size;
    transfer.state = TransferState.running;
    _notifyTransfers();

    final u = _Upload(transfer, file, folder, name, replace);
    _uploads[transfer.id] = u;
    u.timer = Timer(kRequestTimeout, () {
      if (!u.result.isCompleted) {
        u.result.completeError(FsException('timeout', 'No answer from the device.'));
      }
    });
    try {
      if (!session.sendControl(transfer.dev, {
        't': 'fs.write',
        'id': transfer.id,
        'path': folder,
        'name': name,
        'size': size,
        'replace': replace,
      })) {
        throw FsException('send', 'The request could not be queued.');
      }
      final reply = await u.result.future; // fs.write.r arms the send loop
      if (reply['t'] == 'fs.write.r') {
        u.result = Completer<Map<String, Object?>>();
        await _sendUploadBody(u, size);
        u.timer?.cancel();
        u.timer = Timer(kStallTimeout, () {
          if (!u.result.isCompleted) {
            u.result.completeError(
                FsException('timeout', 'No answer from the device.'));
          }
        });
        await u.result.future; // fs.write.done
        transfer.state = TransferState.done;
      }
    } on FsException catch (e) {
      if (transfer.state != TransferState.cancelled) {
        transfer.state = TransferState.failed;
        transfer.error = e.toString();
      }
    } finally {
      u.timer?.cancel();
      _uploads.remove(transfer.id);
      _notifyTransfers();
    }
  }

  Future<void> _sendUploadBody(_Upload u, int size) async {
    final digestSink = _DigestSink();
    final hasher = crypto.sha256.startChunkedConversion(digestSink);
    final stream = u.file.openRead();
    var sent = 0;
    final buffer = BytesBuilder(copy: false);
    Future<void> flushChunks({required bool last}) async {
      while (buffer.length >= kFrameMax || (last && buffer.length > 0)) {
        final take = buffer.length >= kFrameMax ? kFrameMax : buffer.length;
        final all = buffer.takeBytes();
        final chunk = Uint8List.sublistView(all, 0, take);
        if (all.length > take) buffer.add(Uint8List.sublistView(all, take));
        // The peer's queue can be full: pace, never drop.
        while (!session.sendFrame(
            u.transfer.dev, MessageKind.storageUploadData, u.transfer.id, chunk)) {
          if (u.cancelled) throw FsException('cancelled', 'Cancelled.');
          if (session.peers[u.transfer.dev]?.stateCode != 3) {
            throw FsException('disconnected', 'The device disconnected.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        sent += chunk.length;
        u.transfer.done = sent;
        _notifyTransfers();
      }
    }

    await for (final chunk in stream) {
      if (u.cancelled) throw FsException('cancelled', 'Cancelled.');
      hasher.add(chunk);
      buffer.add(chunk);
      await flushChunks(last: false);
    }
    await flushChunks(last: true);
    hasher.close();
    final sha = digestSink.value!.toString();
    session.sendControl(u.transfer.dev, {
      't': 'fs.write.end',
      'id': u.transfer.id,
      'sent': sent,
      'sha256': sha,
    });
  }

  void _onWriteReady(int id) {
    final u = _uploads[id];
    if (u == null || u.result.isCompleted) return;
    u.timer?.cancel();
    u.result.complete({'t': 'fs.write.r'});
  }

  void _onWriteDone(int id, Map<String, Object?> msg) {
    final u = _uploads[id];
    if (u == null || u.result.isCompleted) return;
    u.timer?.cancel();
    u.result.complete(msg);
  }

  void _onWriteErr(int id, Map<String, Object?> msg) {
    final u = _uploads[id];
    if (u == null || u.result.isCompleted) return;
    u.timer?.cancel();
    final code = msg['code'] is String ? msg['code'] as String : 'error';
    u.result.completeError(FsException(code, ''));
  }

  void cancelUpload(Transfer t) {
    final u = _uploads[t.id];
    t.state = TransferState.cancelled;
    if (u != null) {
      u.cancelled = true;
      session.sendControl(t.dev, {'t': 'fs.write.cancel', 'id': t.id});
      if (!u.result.isCompleted) {
        u.result.completeError(FsException('cancelled', 'Cancelled.'));
      }
    }
    _notifyTransfers();
  }

  // --- changes -------------------------------------------------------------

  Future<Map<String, Object?>> mkdir(String dev, String path, String name,
      {bool existing = false}) {
    return _request(dev, {
      't': 'fs.mkdir',
      'id': _takeId(),
      'path': path,
      'name': name,
      'existing': existing,
    });
  }

  Future<Map<String, Object?>> rename(String dev, String path, String name) =>
      _request(dev, {'t': 'fs.rename', 'id': _takeId(), 'path': path, 'name': name});

  Future<Map<String, Object?>> delete(String dev, String path) =>
      _request(dev, {'t': 'fs.delete', 'id': _takeId(), 'path': path});

  Future<Map<String, Object?>> move(String dev, String path, String to) =>
      _request(dev, {'t': 'fs.move', 'id': _takeId(), 'path': path, 'to': to});

  Future<Map<String, Object?>> copy(String dev, String path, String to) =>
      _request(dev, {'t': 'fs.copy', 'id': _takeId(), 'path': path, 'to': to});

  // --- watches -------------------------------------------------------------

  int watch(String dev, String path, void Function(String path) onChanged) {
    final id = _takeId();
    _watches[id] = onChanged;
    _watchDevs[id] = dev;
    session.sendControl(dev, {'t': 'fs.watch', 'id': id, 'path': path});
    return id;
  }

  void unwatch(int id) {
    final dev = _watchDevs.remove(id);
    _watches.remove(id);
    if (dev != null) {
      session.sendControl(dev, {'t': 'fs.unwatch', 'id': id});
    }
  }

  void clearFinishedTransfers() {
    transfers.removeWhere((t) =>
        t.state == TransferState.done ||
        t.state == TransferState.failed ||
        t.state == TransferState.cancelled);
    _notifyTransfers();
  }
}

Future<String> _sha256OfFile(File file) async {
  final sink = _DigestSink();
  final hasher = crypto.sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    hasher.add(chunk);
  }
  hasher.close();
  return sink.value!.toString();
}
