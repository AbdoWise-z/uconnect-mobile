// The offerer side of the storage protocol (docs/protocol.md section 5):
// serves this device's shared folders to peers, checking the peer's
// permission on every request and every upload frame. Paths are virtual --
// a requester never learns where a share really is -- and every resolved
// path must stay inside its share, links acted on but never followed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../permissions.dart';
import '../session.dart';
import '../wire.dart';
import 'storage_client.dart' show kFrameMax, safeLocalName;

class SharedFolder {
  SharedFolder(this.name, this.path, {this.readOnly = false});
  final String name; // what peers see at "/"
  final String path; // where it really is
  final bool readOnly;
}

class StorageActivity {
  StorageActivity(this.time, this.dev, this.line);
  final DateTime time;
  final String dev;
  final String line;
}

class _Read {
  _Read(this.dev, this.id, this.path);
  final String dev;
  final int id;
  final String path;
  bool cancelled = false;
}

class _Write {
  _Write(this.dev, this.id, this.folder, this.name, this.size, this.replace,
      this.tempFile, this.targetDir);
  final String dev;
  final int id;
  final String folder; // virtual target folder
  final String name;
  final int size;
  final bool replace;
  final File tempFile;
  final Directory targetDir;
  IOSink? sink;
  int received = 0;
  final digestSink = DigestSink();
  late final hasher = crypto.sha256.startChunkedConversion(digestSink);
  Timer? stall;
}

class DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

class _Watch {
  _Watch(this.dev, this.id, this.path);
  final String dev;
  final int id;
  final String path;
  String summary = '';
}

class StorageOfferer {
  StorageOfferer(this.session) {
    session.addControlHandler(_onControl);
    session.setFrameHandler(MessageKind.storageUploadData, _onUploadFrame);
    session.addPeerStateHandler(_onPeerState);
    _watchTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollWatches());
  }

  final Session session;
  bool offered = false;
  List<SharedFolder> shares = [];
  int uploadLimit = 0; // bytes; 0 = no limit

  final _reads = <int, _Read>{}; // key: requester id, per peer via dev field
  final _writes = <String, Map<int, _Write>>{}; // dev -> id -> write
  final _watches = <String, Map<int, _Watch>>{};
  Timer? _watchTimer;

  final activity = <StorageActivity>[];
  final _activityChanged = StreamController<void>.broadcast();
  Stream<void> get activityChanged => _activityChanged.stream;

  static const _tempPrefix = '.ucupload-';

  void dispose() {
    _watchTimer?.cancel();
  }

  void _logActivity(String dev, String line) {
    activity.add(StorageActivity(DateTime.now(), dev, line));
    if (activity.length > 200) activity.removeRange(0, activity.length - 200);
    if (!_activityChanged.isClosed) _activityChanged.add(null);
  }

  void _onPeerState(String dev, int state) {
    if (state != 4 && state != 5) return; // failed/closed
    _reads.removeWhere((_, r) {
      if (r.dev == dev) r.cancelled = true;
      return r.dev == dev;
    });
    final writes = _writes.remove(dev);
    if (writes != null) {
      for (final w in writes.values) {
        _discardWrite(w);
      }
    }
    _watches.remove(dev);
  }

  // --- path handling ---------------------------------------------------------

  static final _windowsDevices = RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$',
      caseSensitive: false);

  bool _validComponent(String c) {
    if (c.isEmpty || c == '.' || c == '..' || c.contains('\x00')) return false;
    if (Platform.isWindows) {
      if (c.contains('\\') || c.contains(':')) return false;
      if (_windowsDevices.hasMatch(c)) return false;
    }
    return true;
  }

  List<String>? _splitVirtual(String path) {
    if (!path.startsWith('/')) return null;
    if (path == '/') return [];
    final parts = path.substring(1).split('/');
    for (final p in parts) {
      if (!_validComponent(p)) return null;
    }
    return parts;
  }

  SharedFolder? _share(String name) {
    for (final s in shares) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// Resolves a virtual path to a real one, following links and then
  /// checking the result stays inside the share. Null when it escapes or
  /// does not resolve.
  Future<String?> _resolveInside(SharedFolder share, List<String> sub) async {
    final root = await Directory(share.path).resolveSymbolicLinks();
    var real = share.path;
    for (final c in sub) {
      real = '$real${Platform.pathSeparator}$c';
    }
    try {
      final resolved = await File(real).resolveSymbolicLinks();
      if (resolved != root &&
          !resolved.startsWith('$root${Platform.pathSeparator}')) {
        return null;
      }
      return resolved;
    } on FileSystemException {
      // Does not exist (fine for targets being created): resolve the parent.
      try {
        final parent = File(real).parent;
        final resolvedParent = await parent.resolveSymbolicLinks();
        if (resolvedParent != root &&
            !resolvedParent.startsWith('$root${Platform.pathSeparator}')) {
          return null;
        }
        return '$resolvedParent${Platform.pathSeparator}${sub.isEmpty ? '' : sub.last}';
      } on FileSystemException {
        return null;
      }
    }
  }

  void _err(String dev, int id, String code, String error) {
    session.sendControl(
        dev, {'t': 'fs.err', 'id': id, 'code': code, 'error': error});
  }

  bool _can(String dev, String perm) => session.permissionsFor(dev).contains(perm);

  // --- dispatch --------------------------------------------------------------

  bool _onControl(String dev, Map<String, Object?> msg) {
    final t = msg['t'];
    if (t is! String) return false;
    switch (t) {
      case 'fs.list':
        unawaited(_onList(dev, msg));
      case 'fs.read':
        unawaited(_onRead(dev, msg));
      case 'fs.cancel':
        final id = _intField(msg, 'id');
        if (id != null) {
          final r = _reads[id];
          if (r != null && r.dev == dev) r.cancelled = true;
        }
      case 'fs.write':
        unawaited(_onWrite(dev, msg));
      case 'fs.write.end':
        unawaited(_onWriteEnd(dev, msg));
      case 'fs.write.cancel':
        final id = _intField(msg, 'id');
        final w = id == null ? null : _writes[dev]?.remove(id);
        if (w != null) _discardWrite(w);
      case 'fs.mkdir':
      case 'fs.rename':
      case 'fs.delete':
      case 'fs.move':
      case 'fs.copy':
        unawaited(_onChange(dev, t, msg));
      case 'fs.watch':
        _onWatch(dev, msg);
      case 'fs.unwatch':
        final id = _intField(msg, 'id');
        if (id != null) _watches[dev]?.remove(id);
      default:
        return false; // not ours (fs.* replies belong to the client side)
    }
    return true;
  }

  int? _intField(Map<String, Object?> msg, String key) =>
      msg[key] is num ? (msg[key] as num).toInt() : null;

  bool _gate(String dev, int id, String perm) {
    if (!offered) {
      _err(dev, id, 'not_offered', 'This device does not offer storage.');
      return false;
    }
    if (!_can(dev, perm)) {
      _err(dev, id, 'forbidden', 'Not allowed.');
      return false;
    }
    return true;
  }

  // --- listing ---------------------------------------------------------------

  Future<void> _onList(String dev, Map<String, Object?> msg) async {
    final id = _intField(msg, 'id');
    final path = msg['path'];
    if (id == null || path is! String) return;
    if (!_gate(dev, id, Perm.storageObserve)) return;
    final offset = _intField(msg, 'offset') ?? 0;
    final parts = _splitVirtual(path);
    if (parts == null) return _err(dev, id, 'bad_request', 'Bad path.');

    if (parts.isEmpty) {
      final entries = [
        for (final s in shares)
          {
            'name': s.name,
            'dir': true,
            'size': 0,
            'mtime': 0,
            'readOnly': s.readOnly,
          }
      ];
      final page = entries.skip(offset).take(500).toList();
      session.sendControl(dev, {
        't': 'fs.list.r',
        'id': id,
        'path': path,
        'offset': offset,
        'total': entries.length,
        'readOnly': false,
        'entries': page,
      });
      return;
    }

    final share = _share(parts.first);
    if (share == null) return _err(dev, id, 'not_found', 'No such folder.');
    final real = await _resolveInside(share, parts.sublist(1));
    if (real == null) return _err(dev, id, 'denied', 'Not reachable.');
    final dir = Directory(real);
    if (!await dir.exists()) {
      if (await File(real).exists()) {
        return _err(dev, id, 'not_a_dir', 'Not a folder.');
      }
      return _err(dev, id, 'not_found', 'No such folder.');
    }
    final entries = <Map<String, Object?>>[];
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty,
            orElse: () => '');
        if (!_validComponent(name)) continue;
        if (name.startsWith(_tempPrefix)) continue; // uploads in progress
        if (e is Link) {
          // Only list links that lead back inside the share.
          final inside =
              await _resolveInside(share, [...parts.sublist(1), name]);
          if (inside == null) continue;
        }
        final stat = await e.stat();
        final isDir = stat.type == FileSystemEntityType.directory;
        entries.add({
          'name': name,
          'dir': isDir,
          'size': isDir ? 0 : stat.size,
          'mtime': stat.modified.millisecondsSinceEpoch,
        });
      }
    } on FileSystemException {
      return _err(dev, id, 'denied', 'The folder could not be read.');
    }
    entries.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    final page = entries.skip(offset).take(500).toList();
    session.sendControl(dev, {
      't': 'fs.list.r',
      'id': id,
      'path': path,
      'offset': offset,
      'total': entries.length,
      'readOnly': share.readOnly,
      'entries': page,
    });
  }

  // --- read (their download) ---------------------------------------------------

  Future<void> _onRead(String dev, Map<String, Object?> msg) async {
    final id = _intField(msg, 'id');
    final path = msg['path'];
    if (id == null || path is! String) return;
    if (!_gate(dev, id, Perm.storageRead)) return;
    if (_reads.values.where((r) => r.dev == dev).length >= 4) {
      return _err(dev, id, 'busy', 'Too many transfers; try again later.');
    }
    final parts = _splitVirtual(path);
    if (parts == null || parts.isEmpty) {
      return _err(dev, id, 'bad_request', 'Bad path.');
    }
    final share = _share(parts.first);
    if (share == null) return _err(dev, id, 'not_found', 'No such path.');
    final real = await _resolveInside(share, parts.sublist(1));
    if (real == null) return _err(dev, id, 'denied', 'Not reachable.');
    final file = File(real);
    if (!await file.exists()) {
      if (await Directory(real).exists()) {
        return _err(dev, id, 'not_a_file', 'That is a folder.');
      }
      return _err(dev, id, 'not_found', 'No such file.');
    }

    var offset = _intField(msg, 'offset') ?? 0;
    final size = await file.length();
    if (offset < 0 || offset > size) offset = 0;

    final read = _Read(dev, id, path);
    _reads[id] = read;
    _logActivity(dev, 'read $path');
    session.sendControl(dev,
        {'t': 'fs.read.r', 'id': id, 'size': size, 'offset': offset});
    try {
      final digestSink = DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(digestSink);
      var at = 0;
      await for (final chunk in file.openRead()) {
        if (read.cancelled) break;
        hasher.add(chunk);
        var local = Uint8List.fromList(chunk);
        var start = 0;
        // Bytes before the resume offset are hashed but not sent.
        if (at + local.length <= offset) {
          at += local.length;
          continue;
        }
        if (at < offset) {
          start = offset - at;
        }
        at += local.length;
        var pos = start;
        while (pos < local.length) {
          if (read.cancelled) break;
          final end =
              (pos + kFrameMax) < local.length ? pos + kFrameMax : local.length;
          final frame = Uint8List.sublistView(local, pos, end);
          while (!session.sendFrame(dev, MessageKind.data, id, frame)) {
            if (read.cancelled || session.peers[dev]?.stateCode != 3) {
              read.cancelled = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          pos = end;
        }
      }
      hasher.close();
      if (!read.cancelled) {
        session.sendControl(dev, {
          't': 'fs.read.end',
          'id': id,
          'sent': size,
          'sha256': digestSink.value!.toString(),
        });
      }
    } on FileSystemException {
      if (!read.cancelled) _err(dev, id, 'io', 'Reading failed.');
    } finally {
      _reads.remove(id);
    }
  }

  // --- write (their upload) ---------------------------------------------------

  Future<void> _onWrite(String dev, Map<String, Object?> msg) async {
    final id = _intField(msg, 'id');
    final path = msg['path'];
    final name = msg['name'];
    final size = _intField(msg, 'size');
    final replace = msg['replace'] == true;
    if (id == null || path is! String || name is! String || size == null) {
      return;
    }
    void werr(String code, [String text = '']) => session.sendControl(
        dev, {'t': 'fs.write.err', 'id': id, 'code': code, 'error': text});

    if (!offered) return werr('not_offered');
    if (!_can(dev, Perm.storageUpload)) return werr('forbidden');
    if (replace && !_can(dev, Perm.storageWrite)) return werr('forbidden');
    if ((_writes[dev]?.length ?? 0) >= 4) return werr('busy');
    if (size < 0 || !isCleanName(name)) return werr('bad_request');
    if (uploadLimit > 0 && size > uploadLimit) return werr('too_large');

    final parts = _splitVirtual(path);
    if (parts == null || parts.isEmpty) return werr('bad_request');
    final share = _share(parts.first);
    if (share == null) return werr('not_found');
    if (share.readOnly) return werr('read_only');
    final real = await _resolveInside(share, parts.sublist(1));
    if (real == null) return werr('denied');
    final dir = Directory(real);
    if (!await dir.exists()) return werr('not_found');

    final temp = File('${dir.path}${Platform.pathSeparator}$_tempPrefix$id');
    final w = _Write(dev, id, path, name, size, replace, temp, dir);
    try {
      w.sink = temp.openWrite();
    } on FileSystemException {
      return werr('io');
    }
    (_writes[dev] ??= {})[id] = w;
    _armWriteStall(w);
    _logActivity(dev, 'upload $path/$name ($size bytes)');
    session.sendControl(dev, {'t': 'fs.write.r', 'id': id});
  }

  void _armWriteStall(_Write w) {
    w.stall?.cancel();
    w.stall = Timer(const Duration(seconds: 30), () {
      _writes[w.dev]?.remove(w.id);
      _discardWrite(w);
    });
  }

  void _onUploadFrame(String dev, int id, Uint8List bytes) {
    final w = _writes[dev]?[id];
    if (w == null) return;
    // Permission is checked again on every frame.
    if (!_can(dev, Perm.storageUpload) ||
        bytes.length > kFrameMax ||
        w.received + bytes.length > w.size) {
      _writes[dev]?.remove(id);
      _discardWrite(w);
      session.sendControl(dev, {
        't': 'fs.write.err',
        'id': id,
        'code': !_can(dev, Perm.storageUpload) ? 'forbidden' : 'bad_request',
      });
      return;
    }
    w.hasher.add(bytes);
    w.sink?.add(bytes);
    w.received += bytes.length;
    _armWriteStall(w);
  }

  Future<void> _onWriteEnd(String dev, Map<String, Object?> msg) async {
    final id = _intField(msg, 'id');
    if (id == null) return;
    final w = _writes[dev]?.remove(id);
    if (w == null) return;
    w.stall?.cancel();
    void werr(String code) => session
        .sendControl(dev, {'t': 'fs.write.err', 'id': id, 'code': code});
    final sent = _intField(msg, 'sent') ?? -1;
    final sha = msg['sha256'] is String ? (msg['sha256'] as String) : null;
    try {
      await w.sink?.flush();
      await w.sink?.close();
      w.hasher.close();
      if (!_can(dev, Perm.storageUpload)) {
        await _deleteQuiet(w.tempFile);
        return werr('forbidden');
      }
      if (sent != w.size || w.received != w.size) {
        await _deleteQuiet(w.tempFile);
        return werr('bad_request');
      }
      if (sha != null &&
          sha.toLowerCase() != w.digestSink.value!.toString()) {
        await _deleteQuiet(w.tempFile);
        return werr('corrupt');
      }
      // Resolve the target folder again, then pick the final name.
      final parts = _splitVirtual(w.folder)!;
      final share = _share(parts.first);
      final real =
          share == null ? null : await _resolveInside(share, parts.sublist(1));
      if (real == null || !await Directory(real).exists()) {
        await _deleteQuiet(w.tempFile);
        return werr('not_found');
      }
      var target = File('$real${Platform.pathSeparator}${w.name}');
      if (await _exists(target.path)) {
        if (w.replace) {
          if (await Directory(target.path).exists()) {
            await _deleteQuiet(w.tempFile);
            return werr('bad_request');
          }
        } else {
          target = File(await _numberedName(real, w.name));
        }
      }
      await w.tempFile.rename(target.path);
      final savedName = target.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      session.sendControl(dev, {
        't': 'fs.write.done',
        'id': id,
        'path': '${w.folder == '/' ? '' : w.folder}/$savedName',
      });
    } on FileSystemException {
      await _deleteQuiet(w.tempFile);
      werr('io');
    }
  }

  void _discardWrite(_Write w) {
    w.stall?.cancel();
    unawaited(() async {
      try {
        await w.sink?.close();
      } on FileSystemException {
        // closing a broken sink: nothing to do
      }
      await _deleteQuiet(w.tempFile);
    }());
  }

  Future<void> _deleteQuiet(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // best effort
    }
  }

  Future<bool> _exists(String path) async =>
      await File(path).exists() ||
      await Directory(path).exists() ||
      await Link(path).exists();

  Future<String> _numberedName(String dir, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1;; i++) {
      final candidate = '$dir${Platform.pathSeparator}$stem ($i)$ext';
      if (!await _exists(candidate)) return candidate;
    }
  }

  // --- changes -----------------------------------------------------------------

  Future<void> _onChange(
      String dev, String t, Map<String, Object?> msg) async {
    final id = _intField(msg, 'id');
    final path = msg['path'];
    if (id == null || path is! String) return;
    final needed = switch (t) {
      'fs.mkdir' || 'fs.copy' => Perm.storageUpload,
      _ => Perm.storageWrite,
    };
    if (!_gate(dev, id, needed)) return;
    final parts = _splitVirtual(path);
    if (parts == null) return _err(dev, id, 'bad_request', 'Bad path.');
    if (parts.isEmpty && t != 'fs.mkdir') {
      return _err(dev, id, 'root', 'The shared folders themselves stay put.');
    }
    final share = parts.isEmpty ? null : _share(parts.first);
    if (parts.isNotEmpty && share == null) {
      return _err(dev, id, 'not_found', 'No such path.');
    }
    if (parts.length == 1 && t != 'fs.mkdir') {
      return _err(dev, id, 'root', 'A shared folder cannot be changed.');
    }
    if (share != null && share.readOnly && t != 'fs.copy') {
      return _err(dev, id, 'read_only', 'The share is read-only.');
    }
    try {
      switch (t) {
        case 'fs.mkdir':
          await _mkdir(dev, id, share, parts, msg);
        case 'fs.rename':
          await _rename(dev, id, share!, parts, msg);
        case 'fs.delete':
          await _delete(dev, id, share!, parts, path);
        case 'fs.move':
          await _moveOrCopy(dev, id, share!, parts, msg, copy: false);
        case 'fs.copy':
          await _moveOrCopy(dev, id, share!, parts, msg, copy: true);
      }
    } on FileSystemException {
      _err(dev, id, 'io', 'The operation failed.');
    }
  }

  Future<void> _mkdir(String dev, int id, SharedFolder? share,
      List<String> parts, Map<String, Object?> msg) async {
    final name = msg['name'];
    final existing = msg['existing'] == true;
    if (share == null) return _err(dev, id, 'bad_request', 'Bad path.');
    if (share.readOnly) return _err(dev, id, 'read_only', 'Read-only.');
    if (name is! String || !isCleanName(name)) {
      return _err(dev, id, 'bad_request', 'Bad name.');
    }
    final real = await _resolveInside(share, parts.sublist(1));
    if (real == null) return _err(dev, id, 'denied', 'Not reachable.');
    if (!await Directory(real).exists()) {
      return _err(dev, id, 'not_found', 'No such folder.');
    }
    final virtualBase = parts.length == 1
        ? '/${parts.first}'
        : '/${parts.join('/')}';
    var target = '$real${Platform.pathSeparator}$name';
    if (existing && await Directory(target).exists()) {
      final inside = await _resolveInside(share, [...parts.sublist(1), name]);
      if (inside != null) {
        session.sendControl(dev, {
          't': 'fs.done',
          'id': id,
          'path': '$virtualBase/$name',
          'existed': true,
        });
        return;
      }
    }
    var savedName = name;
    if (await _exists(target)) {
      target = await _numberedName(real, name);
      savedName = target.split(Platform.pathSeparator).last;
    }
    await Directory(target).create();
    _logActivity(dev, 'mkdir $virtualBase/$savedName');
    session.sendControl(
        dev, {'t': 'fs.done', 'id': id, 'path': '$virtualBase/$savedName'});
  }

  Future<void> _rename(String dev, int id, SharedFolder share,
      List<String> parts, Map<String, Object?> msg) async {
    final name = msg['name'];
    if (name is! String || !isCleanName(name)) {
      return _err(dev, id, 'bad_request', 'Bad name.');
    }
    // Resolve the parent, then address the entry inside it (links not followed).
    final parentReal = await _resolveInside(
        share, parts.sublist(1, parts.length - 1));
    if (parentReal == null) return _err(dev, id, 'denied', 'Not reachable.');
    final old = '$parentReal${Platform.pathSeparator}${parts.last}';
    if (!await _exists(old)) return _err(dev, id, 'not_found', 'No such path.');
    final target = '$parentReal${Platform.pathSeparator}$name';
    final caseOnly = parts.last.toLowerCase() == name.toLowerCase() &&
        parts.last != name;
    if (!caseOnly && name != parts.last && await _exists(target)) {
      return _err(dev, id, 'exists', 'The name is taken.');
    }
    if (await File(old).exists()) {
      await File(old).rename(target);
    } else if (await Directory(old).exists()) {
      await Directory(old).rename(target);
    } else {
      await Link(old).rename(target);
    }
    final base = parts.sublist(0, parts.length - 1).join('/');
    _logActivity(dev, 'rename /${parts.join('/')} -> $name');
    session.sendControl(dev, {'t': 'fs.done', 'id': id, 'path': '/$base/$name'});
  }

  Future<void> _delete(String dev, int id, SharedFolder share,
      List<String> parts, String virtualPath) async {
    final parentReal =
        await _resolveInside(share, parts.sublist(1, parts.length - 1));
    if (parentReal == null) return _err(dev, id, 'denied', 'Not reachable.');
    final target = '$parentReal${Platform.pathSeparator}${parts.last}';
    // Deleting a link removes the link, never its target.
    if (await Link(target).exists()) {
      await Link(target).delete();
    } else if (await File(target).exists()) {
      await File(target).delete();
    } else if (await Directory(target).exists()) {
      await Directory(target).delete(recursive: true);
    } else {
      return _err(dev, id, 'not_found', 'No such path.');
    }
    _logActivity(dev, 'delete $virtualPath');
    session.sendControl(dev, {'t': 'fs.done', 'id': id, 'path': virtualPath});
  }

  Future<void> _moveOrCopy(String dev, int id, SharedFolder share,
      List<String> parts, Map<String, Object?> msg,
      {required bool copy}) async {
    final to = msg['to'];
    if (to is! String) return _err(dev, id, 'bad_request', 'Bad target.');
    final toParts = _splitVirtual(to);
    if (toParts == null || toParts.isEmpty) {
      return _err(dev, id, 'bad_request', 'Bad target.');
    }
    final toShare = _share(toParts.first);
    if (toShare == null) return _err(dev, id, 'not_found', 'No such target.');
    // Both ends must be allowed.
    if (copy && toShare.readOnly) {
      return _err(dev, id, 'read_only', 'The target share is read-only.');
    }
    if (!copy && (share.readOnly || toShare.readOnly)) {
      return _err(dev, id, 'read_only', 'A share involved is read-only.');
    }

    final parentReal =
        await _resolveInside(share, parts.sublist(1, parts.length - 1));
    if (parentReal == null) return _err(dev, id, 'denied', 'Not reachable.');
    final source = '$parentReal${Platform.pathSeparator}${parts.last}';
    if (!await _exists(source)) {
      return _err(dev, id, 'not_found', 'No such path.');
    }
    final destDirReal = await _resolveInside(toShare, toParts.sublist(1));
    if (destDirReal == null || !await Directory(destDirReal).exists()) {
      return _err(dev, id, 'not_found', 'No such target folder.');
    }

    // No folder into itself.
    final sourceIsDir = await Directory(source).exists() &&
        !await Link(source).exists();
    if (sourceIsDir) {
      final resolvedSource = await Directory(source).resolveSymbolicLinks();
      if (destDirReal == resolvedSource ||
          destDirReal.startsWith('$resolvedSource${Platform.pathSeparator}')) {
        return _err(dev, id, 'inside', 'A folder cannot go into itself.');
      }
    }

    final name = parts.last;
    // Moving to where it already is succeeds without doing anything.
    if (!copy && destDirReal == parentReal) {
      session.sendControl(dev,
          {'t': 'fs.done', 'id': id, 'path': '${to == '/' ? '' : to}/$name'});
      return;
    }
    var target = '$destDirReal${Platform.pathSeparator}$name';
    var savedName = name;
    if (await _exists(target)) {
      target = await _numberedName(destDirReal, name);
      savedName = target.split(Platform.pathSeparator).last;
    }

    if (copy) {
      if (await Link(source).exists()) {
        return _err(dev, id, 'denied', 'Links are not copied.');
      }
      final progress = Timer.periodic(const Duration(seconds: 3), (_) {
        session.sendControl(dev,
            {'t': 'fs.progress', 'id': id, 'done': 0, 'total': 0});
      });
      try {
        await _copyRecursive(source, target);
      } finally {
        progress.cancel();
      }
    } else {
      try {
        if (sourceIsDir) {
          await Directory(source).rename(target);
        } else if (await Link(source).exists()) {
          await Link(source).rename(target);
        } else {
          await File(source).rename(target);
        }
      } on FileSystemException {
        // Between filesystems: copy then delete (files only, like a rename).
        if (sourceIsDir || await Link(source).exists()) rethrow;
        await _copyRecursive(source, target);
        await File(source).delete();
      }
    }
    _logActivity(dev, '${copy ? 'copy' : 'move'} /${parts.join('/')} -> $to');
    session.sendControl(dev,
        {'t': 'fs.done', 'id': id, 'path': '${to == '/' ? '' : to}/$savedName'});
  }

  Future<void> _copyRecursive(String source, String target) async {
    if (await File(source).exists() && !await Link(source).exists()) {
      await File(source).copy(target);
      return;
    }
    if (await Directory(source).exists()) {
      await Directory(target).create();
      await for (final e in Directory(source).list(followLinks: false)) {
        final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty,
            orElse: () => '');
        if (name.isEmpty || e is Link) continue; // links inside are skipped
        await _copyRecursive(
            e.path, '$target${Platform.pathSeparator}$name');
      }
    }
  }

  // --- watches -----------------------------------------------------------------

  void _onWatch(String dev, Map<String, Object?> msg) {
    final id = _intField(msg, 'id');
    final path = msg['path'];
    if (id == null || path is! String) return;
    if (!offered || !_can(dev, Perm.storageObserve)) return; // no reply either way
    final map = _watches[dev] ??= {};
    if (map.length >= 16) return;
    map[id] = _Watch(dev, id, path);
  }

  Future<String> _summarize(String path) async {
    final parts = _splitVirtual(path);
    if (parts == null) return '!';
    if (parts.isEmpty) {
      return shares.map((s) => '${s.name}/${s.readOnly}').join('|');
    }
    final share = _share(parts.first);
    if (share == null) return '!';
    final real = await _resolveInside(share, parts.sublist(1));
    if (real == null || !await Directory(real).exists()) return '!';
    final lines = <String>[];
    try {
      await for (final e in Directory(real).list(followLinks: false)) {
        final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty,
            orElse: () => '');
        if (name.startsWith(_tempPrefix)) continue;
        final stat = await e.stat();
        lines.add('$name/${stat.type}/${stat.size}/'
            '${stat.modified.millisecondsSinceEpoch}');
      }
    } on FileSystemException {
      return '!';
    }
    lines.sort();
    return lines.join('|');
  }

  Future<void> _pollWatches() async {
    for (final perDev in _watches.values.toList()) {
      for (final w in perDev.values.toList()) {
        // Withdrawn permission ends a watch with no message.
        if (!offered || !_can(w.dev, Perm.storageObserve)) {
          perDev.remove(w.id);
          continue;
        }
        final summary = await _summarize(w.path);
        if (w.summary.isEmpty) {
          w.summary = summary;
          continue;
        }
        if (summary != w.summary) {
          w.summary = summary;
          session.sendControl(
              w.dev, {'t': 'fs.changed', 'id': w.id, 'path': w.path});
          if (summary == '!') perDev.remove(w.id); // one last fs.changed
        }
      }
    }
  }
}

/// Upload names must be components a safe-name filter leaves unchanged.
bool isCleanName(String name) =>
    name.isNotEmpty && name == safeLocalName(name) && !name.startsWith('.ucupload-');
