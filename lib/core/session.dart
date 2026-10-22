// Owns the uconnect node for one topic and speaks the app protocol over it:
// hello / id / perm.granted on connect, then dispatch to the services
// (docs/protocol.md in the uconnect-desktop repository). The shape mirrors
// uconnect-desktop's ucd::Session, adapted to Dart: the node's events arrive
// as a Stream from the FFI pump isolate, and a poll timer does what the
// desktop's worker-thread poll does (publish, lookup, reconnect).

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import '../uconnect/uconnect.dart';
import 'identity.dart';
import 'permissions.dart';
import 'wire.dart';

enum SessionStatus { offline, connecting, online, reconnecting, error }

class PeerRecord {
  PeerRecord(this.devId);

  final String devId; // 32 hex chars
  int stateCode = ucPeerUnknown;
  String closeReason = ''; // set while Closed
  bool stale = false;
  bool relayed = false;
  bool hasHello = false;
  String name = '';
  String os = '';
  List<String> services = const [];

  int messagesSent = 0;
  int messagesReceived = 0;
  int bytesSent = 0;
  int bytesReceived = 0;

  // Identity, as proven in this session.
  String identityState = 'pending'; // "pending" | "verified" | "invalid"
  String identityKey = ''; // hex public key, once verified
  String fingerprint = '';
  bool trusted = false;
  List<String> permissions = const []; // what this device grants it
  List<String> grantedToMe = const []; // what it says it grants this device

  // Internals, mirroring the desktop session's PeerInfo.
  bool inLookup = false;
  int? gone; // ucGone*, while closed
  DateTime lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  bool identityInvalid = false;

  String get displayName => hasHello && name.isNotEmpty ? name : shortId(devId);
}

String shortId(String hex) => hex.length > 8 ? hex.substring(0, 8) : hex;

String stateName(int state) => switch (state) {
      ucPeerProbing => 'probing',
      ucPeerHandshaking => 'handshaking',
      ucPeerConnected => 'connected',
      ucPeerFailed => 'failed',
      ucPeerClosed => 'closed',
      _ => 'unknown',
    };

String goneName(int gone) => switch (gone) {
      ucGoneLocal => 'local',
      ucGoneTimedOut => 'timed out',
      ucGoneGoingAway => 'going away',
      ucGoneShuttingDown => 'shutting down',
      _ => 'unspecified',
    };

/// What this device lets others do. Owned by the app, which pushes a copy to
/// the session whenever it changes.
class AccessPolicy {
  AccessPolicy({Set<String>? defaults, Map<String, Set<String>>? trusted})
      : defaults = defaults ?? {},
        trusted = trusted ?? {};

  Set<String> defaults; // every device that is not trusted
  Map<String, Set<String>> trusted; // public key (hex) -> its own permissions
}

class NodeSnapshot {
  bool running = false;
  bool serverConnected = false;
  bool published = false;
  bool authenticated = false;
  int localPort = 0;
  String reflexive = '';
  String selfId = '';
  String topicId = '';
}

class SessionOptions {
  SessionOptions({
    required this.server,
    required this.creds,
    this.forceRelay = false,
    this.verbose = false,
  });

  final String server;
  final TopicCreds creds;
  final bool forceRelay;
  final bool verbose;
}

/// A control-message handler: returns true when it consumed the message.
typedef ControlHandler = bool Function(String dev, Map<String, Object?> msg);

/// A binary-frame handler for one message kind.
typedef FrameHandler = void Function(String dev, int id, Uint8List bytes);

class Session {
  Session();

  static const _lookupMax = 16;
  static const _lookupTimeoutMs = 2500;
  static const _retryAfter = Duration(seconds: 10);
  static const _pollEvery = Duration(seconds: 3);

  UcNode? _node;
  String _topic = '';
  TopicCreds? _creds;
  Identity? identity;
  Hello _localHello = Hello(name: 'uConnect', os: _osName(), services: const []);
  AccessPolicy _policy = AccessPolicy();

  final peers = <String, PeerRecord>{};
  final snapshot = NodeSnapshot();
  SessionStatus status = SessionStatus.offline;
  String statusDetail = '';
  String? selfId;

  bool _published = false;
  bool _polling = false;
  Timer? _pollTimer;
  StreamSubscription<UcNodeEvent>? _eventsSub;
  final _log = <String>[];

  final _changed = StreamController<void>.broadcast();
  final _logChanged = StreamController<String>.broadcast();

  /// Fires after any peer/snapshot/status change; the UI listens and rebuilds.
  Stream<void> get changed => _changed.stream;
  Stream<String> get logLines => _logChanged.stream;
  List<String> get logHistory => List.unmodifiable(_log);

  final List<ControlHandler> _controlHandlers = [];
  final Map<int, FrameHandler> _frameHandlers = {};
  final List<void Function(String dev, int state)> _peerStateHandlers = [];
  final List<void Function(String dev, Uint8List bytes)> _datagramHandlers = [];
  final List<void Function(String dev, int path)> _datagramPathHandlers = [];

  String get topicId => _topic;
  TopicCreds? get creds => _creds;
  UcNode? get node => _node;
  Hello get localHello => _localHello;

  void addControlHandler(ControlHandler h) => _controlHandlers.add(h);
  void setFrameHandler(int kind, FrameHandler h) => _frameHandlers[kind] = h;
  void addPeerStateHandler(void Function(String dev, int state) h) =>
      _peerStateHandlers.add(h);
  void addDatagramHandler(void Function(String dev, Uint8List bytes) h) =>
      _datagramHandlers.add(h);
  void addDatagramPathHandler(void Function(String dev, int path) h) =>
      _datagramPathHandlers.add(h);

  static String _osName() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  void log(String line) {
    final stamped =
        '${DateTime.now().toIso8601String().substring(11, 19)}  $line';
    _log.add(stamped);
    if (_log.length > 500) _log.removeRange(0, _log.length - 500);
    _logChanged.add(stamped);
  }

  void _notify() {
    if (!_changed.isClosed) _changed.add(null);
  }

  void setLocalHello(Hello hello) {
    _localHello = hello;
    final node = _node;
    if (node != null && _topic.isNotEmpty) {
      node.broadcast(_topic, hello.encode());
    }
  }

  void setAccessPolicy(AccessPolicy policy) {
    _policy = policy;
    final node = _node;
    if (node != null && _topic.isNotEmpty) {
      for (final dev in peers.keys.toList()) {
        if (peers[dev]!.stateCode == ucPeerConnected) _sendGrants(dev);
      }
    }
    _refreshRecords();
  }

  Set<String> permissionsFor(String dev) {
    final p = peers[dev];
    if (p != null && p.identityState == 'verified') {
      final trusted = _policy.trusted[p.identityKey];
      if (trusted != null) return normalizePermissions(trusted);
    }
    return permissionsForUntrusted(normalizePermissions(_policy.defaults));
  }

  bool isTrusted(String dev) {
    final p = peers[dev];
    return p != null &&
        p.identityState == 'verified' &&
        _policy.trusted.containsKey(p.identityKey);
  }

  Future<void> start(SessionOptions options) async {
    await stop();
    status = SessionStatus.connecting;
    statusDetail = 'Starting...';
    _notify();
    try {
      _node = await UcNode.start(UcNodeConfig(
        server: options.server,
        forceRelay: options.forceRelay,
        verbose: options.verbose,
      ));
    } on Object catch (e) {
      status = SessionStatus.error;
      statusDetail = e.toString();
      _notify();
      rethrow;
    }
    _creds = options.creds;
    _topic = options.creds.idHex;
    if (!_node!.join(options.creds)) {
      status = SessionStatus.error;
      statusDetail = 'Could not join the topic: ${lastUconnectError()}';
      _notify();
      return;
    }
    _published = false;
    _eventsSub = _node!.events.listen(_onEvent);
    _pollTimer = Timer.periodic(_pollEvery, (_) => _poll());
    log('Joined topic ${shortId(_topic)} on ${options.server}');
    unawaited(_poll());
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await _eventsSub?.cancel();
    _eventsSub = null;
    final node = _node;
    _node = null;
    if (node != null) await node.dispose();
    peers.clear();
    _published = false;
    selfId = null;
    _topic = '';
    status = SessionStatus.offline;
    statusDetail = '';
    _notify();
  }

  Future<void> dispose() async {
    await stop();
    await _changed.close();
    await _logChanged.close();
  }

  // --- wire out ------------------------------------------------------------

  bool sendControl(String dev, Map<String, Object?> message) {
    final node = _node;
    if (node == null) return false;
    return node.send(_topic, dev, encodeControl(message));
  }

  bool sendFrame(String dev, int kind, int id, List<int> bytes) {
    final node = _node;
    if (node == null) return false;
    return node.send(_topic, dev, encodeDataFrame(kind, id, bytes));
  }

  // --- poll ----------------------------------------------------------------

  Future<void> _poll() async {
    final node = _node;
    if (node == null || _polling) return;
    _polling = true;
    try {
      if (!_published) {
        // Unlisted, empty meta: a private device group has no business in the
        // public directory, and names travel in the encrypted hello instead.
        _published = await node.publish(_topic, unlisted: true);
        if (_node != node) return; // stopped while we were publishing
        if (!_published) {
          status = SessionStatus.connecting;
          statusDetail = 'Waiting for the rendezvous server...';
          _updateSnapshot(node);
          _notify();
          return;
        }
        selfId = node.self(_topic);
        log('Published as ${shortId(selfId ?? '?')}'
            '${node.reflexive != null ? ' (server sees ${node.reflexive})' : ''}');
      }

      final list = await node.peers(_topic,
          max: _lookupMax, timeoutMs: _lookupTimeoutMs);
      if (_node != node) return;
      for (final p in peers.values) {
        p.inLookup = false;
      }
      for (final info in list) {
        if (info.devHex == selfId) continue;
        final p = peers.putIfAbsent(info.devHex, () => PeerRecord(info.devHex));
        p.inLookup = true;
        p.stale = info.stale;
      }
      final now = DateTime.now();
      peers.removeWhere((dev, p) {
        final st = node.peerState(_topic, dev);
        return !p.inLookup && !_isActive(st);
      });
      for (final entry in peers.entries) {
        final p = entry.value;
        if (!p.inLookup || p.stale) continue;
        final st = node.peerState(_topic, entry.key);
        // A peer that said goodbye on purpose is left alone; one that
        // vanished or could not be reached is retried, but not hammered.
        final deliberate = p.gone != null && p.gone != ucGoneTimedOut;
        final retry = (st == ucPeerFailed || (st == ucPeerClosed && !deliberate)) &&
            now.difference(p.lastAttempt) > _retryAfter;
        if (st == ucPeerUnknown || retry) {
          p.lastAttempt = now;
          node.connect(_topic, entry.key);
        }
      }
      _updateStatus(node);
    } finally {
      _polling = false;
    }
    _refreshRecords();
  }

  bool _isActive(int state) =>
      state == ucPeerProbing ||
      state == ucPeerHandshaking ||
      state == ucPeerConnected;

  void _updateStatus(UcNode node) {
    if (!_published) return;
    if (node.serverConnected) {
      status = SessionStatus.online;
      statusDetail = 'Connected to the rendezvous server';
    } else {
      status = SessionStatus.reconnecting;
      statusDetail = 'Lost the rendezvous server; retrying...';
    }
  }

  void _updateSnapshot(UcNode node) {
    snapshot
      ..running = node.isRunning
      ..serverConnected = node.serverConnected
      ..published = _published
      ..authenticated = _topic.isNotEmpty && node.isAuthenticated(_topic)
      ..localPort = node.localPort
      ..reflexive = node.reflexive ?? ''
      ..selfId = selfId ?? ''
      ..topicId = _topic;
  }

  void _refreshRecords() {
    final node = _node;
    if (node == null) return;
    for (final entry in peers.entries) {
      final p = entry.value;
      p.stateCode = node.peerState(_topic, entry.key);
      p.closeReason = p.stateCode == ucPeerClosed && p.gone != null
          ? goneName(p.gone!)
          : '';
      final link = node.link(_topic, entry.key);
      if (link != null) {
        p.relayed = link.relayed;
        p.messagesSent = link.messagesSent;
        p.messagesReceived = link.messagesReceived;
        p.bytesSent = link.bytesSent;
        p.bytesReceived = link.bytesReceived;
      }
      p.trusted =
          p.identityState == 'verified' && _policy.trusted.containsKey(p.identityKey);
      p.permissions = permissionsFor(entry.key).toList()..sort();
    }
    _updateSnapshot(node);
    _notify();
  }

  // --- events --------------------------------------------------------------

  void _onEvent(UcNodeEvent event) {
    if (event.topicHex != _topic) return;
    switch (event.kind) {
      case ucEventPeer:
        _onPeerState(event.devHex, event.aux);
      case ucEventPeerClosed:
        final p = peers[event.devHex];
        if (p != null) p.gone = event.aux;
        log('Peer ${shortId(event.devHex)} closed: ${goneName(event.aux)}');
        _refreshRecords();
      case ucEventData:
        _onData(event.devHex, event.data ?? Uint8List(0));
      case ucEventDatagram:
        for (final h in _datagramHandlers) {
          h(event.devHex, event.data ?? Uint8List(0));
        }
      case ucEventDatagramPath:
        for (final h in _datagramPathHandlers) {
          h(event.devHex, event.aux);
        }
    }
  }

  void _onPeerState(String dev, int state) {
    if (dev == selfId) return;
    final p = peers.putIfAbsent(dev, () => PeerRecord(dev));
    log('Peer ${shortId(dev)} -> ${stateName(state)}');
    if (state == ucPeerConnected) {
      p.gone = null;
      p.identityState = 'pending';
      p.identityKey = '';
      p.fingerprint = '';
      p.identityInvalid = false;
      p.grantedToMe = const [];
      final node = _node;
      if (node != null) {
        node.send(_topic, dev, _localHello.encode());
        unawaited(_sendIdentity(dev));
        _sendGrants(dev);
      }
    } else if (state == ucPeerClosed || state == ucPeerFailed) {
      p.identityState = 'pending';
      p.identityKey = '';
      p.fingerprint = '';
      p.identityInvalid = false;
      p.grantedToMe = const [];
    }
    for (final h in _peerStateHandlers) {
      h(dev, state);
    }
    _refreshRecords();
  }

  Future<void> _sendIdentity(String dev) async {
    final node = _node;
    final id = identity;
    if (node == null || id == null) return;
    final binding = node.channelBinding(_topic, dev);
    if (binding == null) return;
    final proof = await id.proof(binding);
    if (_node == node) sendControl(dev, proof);
  }

  // Tells a peer what it may do here, so its UI can say so up front. Purely
  // informative: every request is still checked when it arrives.
  void _sendGrants(String dev) {
    final granted = permissionsFor(dev).toList()..sort();
    sendControl(dev, {'t': 'perm.granted', 'perms': granted});
  }

  void _onData(String dev, Uint8List data) {
    final msg = decodeControl(data);
    if (msg != null) {
      final t = msg['t'];
      if (t == 'hello') {
        final hello = Hello.fromJson(msg);
        if (hello == null) return;
        final p = peers.putIfAbsent(dev, () => PeerRecord(dev));
        final first = !p.hasHello;
        p.hasHello = true;
        p.name = hello.name;
        p.os = hello.os;
        p.services = hello.services;
        if (first) {
          log('Peer ${shortId(dev)} is "${hello.name}" (${hello.os}) '
              'offering [${hello.services.join(', ')}]');
        }
        _refreshRecords();
        return;
      }
      if (t == 'id') {
        unawaited(_onIdentity(dev, msg));
        return;
      }
      if (t == 'perm.granted') {
        _onGrants(dev, msg);
        return;
      }
      for (final h in _controlHandlers) {
        if (h(dev, msg)) return;
      }
      // Unknown control types are ignored, as the protocol requires.
      return;
    }
    final frame = decodeDataFrame(data);
    if (frame != null) {
      final h = _frameHandlers[frame.kind];
      if (h != null) {
        h(dev, frame.id, frame.bytes);
        return;
      }
    }
    log('Peer ${shortId(dev)} sent ${data.length} bytes of an unknown message kind');
  }

  Future<void> _onIdentity(String dev, Map<String, Object?> msg) async {
    final node = _node;
    final p = peers.putIfAbsent(dev, () => PeerRecord(dev));
    if (p.identityState == 'verified' || p.identityInvalid) {
      return; // one proof per session
    }
    final binding = node?.channelBinding(_topic, dev);
    final key = binding == null ? null : await verifyProof(msg, binding);
    if (_node != node) return;
    if (key != null) {
      p.identityState = 'verified';
      p.identityKey = key;
      p.fingerprint = fingerprintOfHex(key);
      log('Peer ${shortId(dev)} proved identity ${p.fingerprint}');
    } else {
      p.identityInvalid = true;
      p.identityState = 'invalid';
      log('Peer ${shortId(dev)} sent an identity proof that does not verify');
    }
    _sendGrants(dev); // what it may do depends on who it turned out to be
    _refreshRecords();
  }

  void _onGrants(String dev, Map<String, Object?> msg) {
    final granted = <String>[
      if (msg['perms'] is List)
        for (final v in msg['perms'] as List)
          if (v is String && isKnownPermission(v)) v
    ];
    peers.putIfAbsent(dev, () => PeerRecord(dev)).grantedToMe = granted;
    _refreshRecords();
  }

  // --- user actions --------------------------------------------------------

  void connectPeer(String dev) {
    final p = peers[dev];
    p?.lastAttempt = DateTime.now();
    _node?.connect(_topic, dev);
    _refreshRecords();
  }

  void disconnectPeer(String dev) {
    _node?.disconnect(_topic, dev);
    _refreshRecords();
  }

  Future<void> refreshNow() => _poll();
}
