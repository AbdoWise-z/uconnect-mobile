// Dart-friendly layer over the uconnect C ABI (bindings.dart).
//
// Threading: the uconnect node runs its own loop thread inside the library.
// Dart must never be entered from that thread, so no C callbacks are
// registered; instead every joined topic is switched to the C API's event
// queue, and a dedicated pump isolate drains it and forwards events to the
// main isolate as a Stream. Library calls that can block for a network
// round-trip (publish, peers, resolve, stats) run via Isolate.run; quick
// state queries and sends are called directly.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

export 'bindings.dart'
    show
        ucPeerUnknown,
        ucPeerProbing,
        ucPeerHandshaking,
        ucPeerConnected,
        ucPeerFailed,
        ucPeerClosed,
        ucGoneLocal,
        ucGoneTimedOut,
        ucGoneGoingAway,
        ucGoneShuttingDown,
        ucGoneUnspecified,
        ucFallbackTcp,
        ucFallbackRelay,
        ucFallbackNone,
        ucPathNone,
        ucPathOpening,
        ucPathDirect,
        ucPathRelayed,
        ucPathTcp,
        ucPathFailed,
        ucEventPeer,
        ucEventData,
        ucEventDatagram,
        ucEventDatagramPath,
        ucEventPeerClosed;

UcBindings? _bindings;

/// The bindings for this isolate, resolved on first use.
UcBindings get ucBindings => _bindings ??= UcBindings(openUconnectLibrary());

const _hexDigits = '0123456789abcdef';

String bytesToHex(Uint8List bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(_hexDigits[(b >> 4) & 0xF]);
    out.write(_hexDigits[b & 0xF]);
  }
  return out.toString();
}

Uint8List? hexToBytes(String hex) {
  if (hex.length.isOdd) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = int.tryParse(hex[2 * i], radix: 16);
    final lo = int.tryParse(hex[2 * i + 1], radix: 16);
    if (hi == null || lo == null) return null;
    out[i] = (hi << 4) | lo;
  }
  return out;
}

void _arrayStore(Array<Uint8> dst, Uint8List src, int n) {
  for (var i = 0; i < n; i++) {
    dst[i] = src[i];
  }
}

Uint8List _arrayLoad(Array<Uint8> src, int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = src[i];
  }
  return out;
}

/// A topic's identity and (for keyed topics) its secret, as in the
/// `uconn://<topic id>#<key>` invite link.
class TopicCreds {
  TopicCreds._(this.id, this.key);

  final Uint8List id; // 16 bytes
  final Uint8List? key; // 32 bytes, null for an open topic

  bool get keyed => key != null;
  String get idHex => bytesToHex(id);

  static TopicCreds? parse(String uri) {
    final b = ucBindings;
    final uriPtr = uri.toNativeUtf8();
    final out = calloc<UcTopicCreds>();
    try {
      if (!b.credsParse(uriPtr, out)) return null;
      return TopicCreds._fromNative(out.ref);
    } finally {
      calloc.free(uriPtr);
      calloc.free(out);
    }
  }

  static TopicCreds generate({bool keyed = true}) {
    final b = ucBindings;
    final out = calloc<UcTopicCreds>();
    try {
      if (!b.credsGenerate(keyed, out)) {
        throw StateError('no randomness: ${lastUconnectError()}');
      }
      return TopicCreds._fromNative(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  static TopicCreds _fromNative(UcTopicCreds c) => TopicCreds._(
        _arrayLoad(c.id.bytes, 16),
        c.keyed ? _arrayLoad(c.key.bytes, 32) : null,
      );

  Pointer<UcTopicCreds> _toNative() {
    final out = calloc<UcTopicCreds>();
    _arrayStore(out.ref.id.bytes, id, 16);
    out.ref.keyed = keyed;
    if (key != null) _arrayStore(out.ref.key.bytes, key!, 32);
    return out;
  }

  String toUri() {
    final b = ucBindings;
    final c = _toNative();
    final buf = calloc<Uint8>(ucUriMax).cast<Utf8>();
    try {
      final len = b.credsToUri(c, buf, ucUriMax);
      return buf.cast<Utf8>().toDartString(length: len);
    } finally {
      calloc.free(c);
      calloc.free(buf);
    }
  }
}

String lastUconnectError() {
  final p = ucBindings.lastError();
  return p == nullptr ? '' : p.toDartString();
}

class UcNodeConfig {
  UcNodeConfig({
    required this.server,
    this.bindPort,
    this.keepaliveS,
    this.punchTimeoutS,
    this.forceRelay,
    this.verbose,
    this.datagramFallback,
    this.rekeyShift,
  });

  final String server;
  final int? bindPort;
  final int? keepaliveS;
  final int? punchTimeoutS;
  final bool? forceRelay;
  final bool? verbose;
  final int? datagramFallback;
  final int? rekeyShift;
}

/// One event drained from the node's queue, with ids as lowercase hex.
class UcNodeEvent {
  UcNodeEvent(this.kind, this.topicHex, this.devHex, this.aux, this.data);

  final int kind; // ucEvent*
  final String topicHex; // 32 hex chars
  final String devHex; // 32 hex chars
  final int aux; // peer state, datagram path or gone reason, per kind
  final Uint8List? data; // for data and datagram events

  @override
  String toString() => 'UcNodeEvent(kind=$kind dev=$devHex aux=$aux '
      'len=${data?.length ?? 0})';
}

class PeerListEntry {
  PeerListEntry(this.devHex, this.ageS, this.stale, this.meta);
  final String devHex;
  final int ageS;
  final bool stale;
  final Uint8List? meta;
}

class LinkInfo {
  LinkInfo(this.relayed, this.messagesSent, this.messagesReceived,
      this.bytesSent, this.bytesReceived);
  final bool relayed;
  final int messagesSent;
  final int messagesReceived;
  final int bytesSent;
  final int bytesReceived;
}

class _PumpArgs {
  _PumpArgs(this.nodeAddr, this.events);
  final int nodeAddr;
  final SendPort events;
}

const _pumpExit = '__pump_exit__';

void _pumpMain(_PumpArgs args) {
  final b = UcBindings(openUconnectLibrary());
  final node = Pointer<NativeNode>.fromAddress(args.nodeAddr);
  while (true) {
    final ev = b.nodeNextEvent(node, 1000);
    if (ev == nullptr) {
      // Timeout, or the queue drained after shutdown -- which is the only
      // time next_event returns at once with nothing.
      if (!b.nodeIsRunning(node)) break;
      continue;
    }
    final e = ev.ref;
    TransferableTypedData? data;
    if (e.kind == ucEventData || e.kind == ucEventDatagram) {
      data = TransferableTypedData.fromList(
          [e.data == nullptr ? Uint8List(0) : e.data.asTypedList(e.len)]);
    }
    final aux = switch (e.kind) {
      ucEventPeer => e.peerState,
      ucEventDatagramPath => e.datagramPath,
      ucEventPeerClosed => e.peerGone,
      _ => 0,
    };
    args.events.send([
      e.kind,
      _arrayLoad(e.topic.bytes, 16),
      _arrayLoad(e.dev.bytes, 16),
      aux,
      data,
    ]);
    b.eventFree(ev);
  }
  args.events.send(_pumpExit);
}

// Top-level entry points for Isolate.run: closures must capture only
// sendable values, so each takes plain ints/lists and reopens the library.
List<List<Object?>> _peersBlocking(
    (int, Uint8List, int, bool, int) a) {
  final b = UcBindings(openUconnectLibrary());
  final node = Pointer<NativeNode>.fromAddress(a.$1);
  final tid = calloc<UcTopicId>();
  _arrayStore(tid.ref.bytes, a.$2, 16);
  final list = b.topicPeers(node, tid.ref, a.$3, a.$4, a.$5);
  calloc.free(tid);
  if (list == nullptr) return const [];
  final out = <List<Object?>>[];
  final info = calloc<UcPeerInfo>();
  final n = b.peerListSize(list);
  for (var i = 0; i < n; i++) {
    if (!b.peerListGet(list, i, info)) break;
    final r = info.ref;
    out.add([
      _arrayLoad(r.devId.bytes, 16),
      r.ageS,
      r.stale,
      r.metaLen > 0 && r.meta != nullptr
          ? Uint8List.fromList(r.meta.asTypedList(r.metaLen))
          : null,
    ]);
  }
  calloc.free(info);
  b.peerListFree(list);
  return out;
}

bool _publishBlocking((int, Uint8List, Uint8List, bool) a) {
  final b = UcBindings(openUconnectLibrary());
  final node = Pointer<NativeNode>.fromAddress(a.$1);
  final tid = calloc<UcTopicId>();
  _arrayStore(tid.ref.bytes, a.$2, 16);
  final meta = a.$3;
  final buf = meta.isEmpty ? nullptr.cast<Uint8>() : calloc<Uint8>(meta.length);
  if (meta.isNotEmpty) buf.asTypedList(meta.length).setAll(0, meta);
  final ok = b.topicPublish(node, tid.ref, buf, meta.length, a.$4);
  if (meta.isNotEmpty) calloc.free(buf);
  calloc.free(tid);
  return ok;
}

/// A running uconnect node: one TCP port, the library's loop thread, and the
/// topics joined through it. Mirrors the shape of uconnect.hpp's Node/Topic,
/// addressing topics and peers by lowercase-hex ids as the C ABI does.
class UcNode {
  UcNode._(this._node, this._events, this._pumpDone);

  final Pointer<NativeNode> _node;
  final StreamController<UcNodeEvent> _events;
  final Future<void> _pumpDone;
  bool _shutdown = false;
  int _inflight = 0; // blocking calls running on other isolates

  Stream<UcNodeEvent> get events => _events.stream;

  static Future<UcNode> start(UcNodeConfig config) async {
    final b = ucBindings;
    final cfg = calloc<NativeNodeConfig>();
    final server = config.server.toNativeUtf8();
    Pointer<NativeNode> node;
    try {
      b.nodeConfigInit(cfg.cast());
      final c = cfg.ref;
      c.server = server;
      if (config.bindPort != null) c.bindPort = config.bindPort!;
      if (config.keepaliveS != null) c.keepaliveS = config.keepaliveS!;
      if (config.punchTimeoutS != null) c.punchTimeoutS = config.punchTimeoutS!;
      if (config.forceRelay != null) c.forceRelay = config.forceRelay!;
      if (config.verbose != null) c.verbose = config.verbose!;
      if (config.datagramFallback != null) {
        c.datagramFallback = config.datagramFallback!;
      }
      if (config.rekeyShift != null) c.rekeyShift = config.rekeyShift!;
      node = b.nodeNew(cfg.cast());
    } finally {
      calloc.free(server);
      calloc.free(cfg);
    }
    if (node == nullptr) {
      throw StateError('uconnect node: ${lastUconnectError()}');
    }
    b.nodeRunInBackground(node);

    final controller = StreamController<UcNodeEvent>.broadcast();
    final fromPump = ReceivePort();
    final pumpDone = Completer<void>();
    fromPump.listen((m) {
      if (m == _pumpExit) {
        fromPump.close();
        pumpDone.complete();
        return;
      }
      final list = m as List;
      final ttd = list[4] as TransferableTypedData?;
      controller.add(UcNodeEvent(
        list[0] as int,
        bytesToHex(list[1] as Uint8List),
        bytesToHex(list[2] as Uint8List),
        list[3] as int,
        ttd?.materialize().asUint8List(),
      ));
    });
    await Isolate.spawn(_pumpMain, _PumpArgs(node.address, fromPump.sendPort),
        debugName: 'uconnect-pump');
    return UcNode._(node, controller, pumpDone.future);
  }

  /// Shuts the node down, waits for the pump and any blocking call still
  /// inside the library to return, and frees it. uconnect_node_free must not
  /// run while another thread is inside a call on the node; shutdown wakes
  /// them, so the waits below are short.
  Future<void> dispose() async {
    if (_shutdown) return;
    _shutdown = true;
    ucBindings.nodeShutdown(_node);
    await _pumpDone.timeout(const Duration(seconds: 10), onTimeout: () {});
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (_inflight > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    ucBindings.nodeFree(_node);
    await _events.close();
  }

  Future<T> _blocking<T>(Future<T> Function() run, T whenDown) async {
    if (_shutdown) return whenDown;
    _inflight++;
    try {
      return await run();
    } finally {
      _inflight--;
    }
  }

  bool get isRunning => ucBindings.nodeIsRunning(_node);
  bool get serverConnected => ucBindings.nodeServerConnected(_node);
  int get localPort => ucBindings.nodeLocalPort(_node);
  int get maxMessage => ucBindings.maxMessage();
  int get maxDatagram => ucBindings.maxDatagram();

  String? get reflexive {
    final ep = calloc<UcEndpoint>();
    try {
      if (!ucBindings.nodeReflexive(_node, ep)) return null;
      final e = ep.ref;
      if (e.family == 4) {
        final a = _arrayLoad(e.addr, 4);
        return '${a[0]}.${a[1]}.${a[2]}.${a[3]}:${e.port}';
      }
      final a = _arrayLoad(e.addr, 16);
      final groups = <String>[];
      for (var i = 0; i < 16; i += 2) {
        groups.add(((a[i] << 8) | a[i + 1]).toRadixString(16));
      }
      return '[${groups.join(':')}]:${e.port}';
    } finally {
      calloc.free(ep);
    }
  }

  Pointer<UcTopicId> _tid(String topicHex) {
    final bytes = hexToBytes(topicHex);
    if (bytes == null || bytes.length != 16) {
      throw ArgumentError('bad topic id: $topicHex');
    }
    final p = calloc<UcTopicId>();
    _arrayStore(p.ref.bytes, bytes, 16);
    return p;
  }

  Pointer<UcDevId> _did(String devHex) {
    final bytes = hexToBytes(devHex);
    if (bytes == null || bytes.length != 16) {
      throw ArgumentError('bad dev id: $devHex');
    }
    final p = calloc<UcDevId>();
    _arrayStore(p.ref.bytes, bytes, 16);
    return p;
  }

  /// Joins and switches the topic to queued events (so they reach [events]).
  bool join(TopicCreds creds) {
    final c = creds._toNative();
    try {
      if (!ucBindings.nodeJoin(_node, c)) return false;
      final tid = _tid(creds.idHex);
      ucBindings.topicQueueEvents(_node, tid.ref);
      calloc.free(tid);
      return true;
    } finally {
      calloc.free(c);
    }
  }

  TopicCreds? create({bool keyed = true}) {
    final out = calloc<UcTopicCreds>();
    try {
      if (!ucBindings.nodeCreate(_node, keyed, out)) return null;
      final creds = TopicCreds._fromNative(out.ref);
      final tid = _tid(creds.idHex);
      ucBindings.topicQueueEvents(_node, tid.ref);
      calloc.free(tid);
      return creds;
    } finally {
      calloc.free(out);
    }
  }

  void leave(String topicHex) {
    final tid = _tid(topicHex);
    ucBindings.nodeLeave(_node, tid.ref);
    calloc.free(tid);
  }

  /// Registers with the server; a server round-trip, so run off this isolate.
  Future<bool> publish(String topicHex,
      {Uint8List? meta, bool unlisted = false}) {
    final t = hexToBytes(topicHex)!;
    final addr = _node.address;
    final bytes = meta ?? Uint8List(0);
    return _blocking(
        () => Isolate.run(() => _publishBlocking((addr, t, bytes, unlisted))),
        false);
  }

  void unpublish(String topicHex) {
    final tid = _tid(topicHex);
    ucBindings.topicUnpublish(_node, tid.ref);
    calloc.free(tid);
  }

  String? self(String topicHex) {
    final tid = _tid(topicHex);
    final out = calloc<UcDevId>();
    try {
      if (!ucBindings.topicSelf(_node, tid.ref, out)) return null;
      return bytesToHex(_arrayLoad(out.ref.bytes, 16));
    } finally {
      calloc.free(tid);
      calloc.free(out);
    }
  }

  /// A lookup at the server; runs off this isolate.
  Future<List<PeerListEntry>> peers(String topicHex,
      {int max = 32,
      bool wantMeta = false,
      int timeoutMs = ucDefaultTimeoutMs}) async {
    final t = hexToBytes(topicHex)!;
    final addr = _node.address;
    final rows = await _blocking(
        () => Isolate.run(() => _peersBlocking((addr, t, max, wantMeta, timeoutMs))),
        const <List<Object?>>[]);
    return [
      for (final r in rows)
        PeerListEntry(bytesToHex(r[0] as Uint8List), r[1] as int, r[2] as bool,
            r[3] as Uint8List?)
    ];
  }

  void connect(String topicHex, String devHex) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    ucBindings.topicConnect(_node, tid.ref, did.ref);
    calloc.free(tid);
    calloc.free(did);
  }

  void connectAll(String topicHex, {int maxPeers = 8}) {
    final tid = _tid(topicHex);
    ucBindings.topicConnectAll(_node, tid.ref, maxPeers);
    calloc.free(tid);
  }

  void disconnect(String topicHex, String devHex) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    ucBindings.topicDisconnect(_node, tid.ref, did.ref);
    calloc.free(tid);
    calloc.free(did);
  }

  List<String> connected(String topicHex, {int cap = 64}) {
    final tid = _tid(topicHex);
    final out = calloc<UcDevId>(cap);
    try {
      final n = ucBindings.topicConnected(_node, tid.ref, out, cap);
      final count = n < cap ? n : cap;
      return [
        for (var i = 0; i < count; i++)
          bytesToHex(_arrayLoad(out[i].bytes, 16))
      ];
    } finally {
      calloc.free(tid);
      calloc.free(out);
    }
  }

  int peerState(String topicHex, String devHex) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    final s = ucBindings.topicState(_node, tid.ref, did.ref);
    calloc.free(tid);
    calloc.free(did);
    return s;
  }

  LinkInfo? link(String topicHex, String devHex) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    final out = calloc<UcLinkInfo>();
    try {
      if (!ucBindings.topicLink(_node, tid.ref, did.ref, out)) return null;
      final r = out.ref;
      return LinkInfo(r.relayed, r.messagesSent, r.messagesReceived,
          r.bytesSent, r.bytesReceived);
    } finally {
      calloc.free(tid);
      calloc.free(did);
      calloc.free(out);
    }
  }

  bool send(String topicHex, String devHex, Uint8List data) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    final buf = calloc<Uint8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    final ok =
        ucBindings.topicSend(_node, tid.ref, did.ref, buf, data.length);
    calloc.free(buf);
    calloc.free(tid);
    calloc.free(did);
    return ok;
  }

  int broadcast(String topicHex, Uint8List data) {
    final tid = _tid(topicHex);
    final buf = calloc<Uint8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    final n = ucBindings.topicBroadcast(_node, tid.ref, buf, data.length);
    calloc.free(buf);
    calloc.free(tid);
    return n;
  }

  bool openDatagrams(String topicHex, String devHex, int fallback) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    final ok =
        ucBindings.topicOpenDatagrams(_node, tid.ref, did.ref, fallback);
    calloc.free(tid);
    calloc.free(did);
    return ok;
  }

  void closeDatagrams(String topicHex, String devHex) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    ucBindings.topicCloseDatagrams(_node, tid.ref, did.ref);
    calloc.free(tid);
    calloc.free(did);
  }

  int datagramPath(String topicHex, String devHex) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    final p = ucBindings.topicDatagramPath(_node, tid.ref, did.ref);
    calloc.free(tid);
    calloc.free(did);
    return p;
  }

  bool sendDatagram(String topicHex, String devHex, Uint8List data) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    final buf = calloc<Uint8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    final ok = ucBindings.topicSendDatagram(
        _node, tid.ref, did.ref, buf, data.length);
    calloc.free(buf);
    calloc.free(tid);
    calloc.free(did);
    return ok;
  }

  void setAutoConnect(String topicHex, bool on) {
    final tid = _tid(topicHex);
    ucBindings.topicSetAutoConnect(_node, tid.ref, on);
    calloc.free(tid);
  }

  void setMaxPeers(String topicHex, int n) {
    final tid = _tid(topicHex);
    ucBindings.topicSetMaxPeers(_node, tid.ref, n);
    calloc.free(tid);
  }

  bool isAuthenticated(String topicHex) {
    final tid = _tid(topicHex);
    final ok = ucBindings.topicIsAuthenticated(_node, tid.ref);
    calloc.free(tid);
    return ok;
  }

  /// The uconnect session's channel binding with this peer: what the identity
  /// proof signs over.
  Uint8List? channelBinding(String topicHex, String devHex) {
    final tid = _tid(topicHex);
    final did = _did(devHex);
    final out = calloc<Uint8>(32);
    try {
      if (!ucBindings.topicChannelBinding(_node, tid.ref, did.ref, out)) {
        return null;
      }
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      calloc.free(tid);
      calloc.free(did);
      calloc.free(out);
    }
  }
}
