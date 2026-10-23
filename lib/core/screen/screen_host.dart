// Host side of screen sharing (docs/protocol.md section 7): this device
// shares its screen to a peer that asks. It answers scr.request (after a
// permission check and, unless the peer holds screen.direct, a consent
// prompt), captures and encodes via CaptureController, fragments each access
// unit into video datagrams, and honors the viewer's feedback (scr.nack,
// scr.keyframe, scr.report). One viewer at a time in this version.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../permissions.dart';
import '../session.dart';
import '../../uconnect/uconnect.dart' show ucPathDirect, ucPathRelayed;
import 'remote_input.dart';
import 'screen_capture.dart';
import 'stream_control.dart';

enum HostState { idle, sharing }

/// Asks the user to allow a peer to view this screen (or, with `control: true`,
/// to also control it). Return true to allow.
typedef ConsentAsk = Future<bool> Function(String dev, String name,
    {bool control, bool camera});

class ScreenHost {
  ScreenHost(this.session, this.capture, this.input,
      {required this.askConsent,
      this.prefix = 'scr',
      this.videoKind = 1,
      this.viewPerm = Perm.screenView,
      this.directPerm = Perm.screenDirect}) {
    session.addControlHandler(_onControl);
    session.addPeerStateHandler((dev, state) {
      if (dev == _viewer && (state == 4 || state == 5)) _teardown();
    });
  }

  final Session session;
  final VideoSource capture;
  final RemoteInput input;
  final ConsentAsk askConsent;

  /// 'scr' for a screen, 'cam' for a camera: the control-message prefix and
  /// video datagram kind (1 vs 3) differ; a camera has no control channel and
  /// always asks for consent (no "direct" grant).
  final String prefix;
  final int videoKind;
  final String viewPerm;
  final String? directPerm;

  /// Source-side caps on what to encode (0 = no cap): the screen-sharing and
  /// camera settings bound a viewer's request down to these.
  int maxWidthCap = 0;
  int maxFpsCap = 0;
  int maxBitrateCap = 0;

  bool get _supportsControl => prefix == 'scr';
  // The source (camera) currently being captured, index into capture.sources().
  int _monitor = 0;

  /// Whether this device offers screen sharing at all; mirrors the hello.
  bool offered = false;

  /// Whether this device offers remote control (needs the accessibility
  /// service enabled); mirrors the `control` service in the hello.
  bool offerControl = false;
  bool _controlOn = false;
  bool get controlling => _controlOn;

  HostState state = HostState.idle;
  String? _viewer; // the watching peer's dev id
  int _request = 0;
  int _session = 0;
  int _seq = 0;
  int _width = 0;
  int _height = 0;
  int _fps = 30;
  // This session's bitrate, within its cap: the settings', or the viewer's if lower.
  BitrateControl _rate = BitrateControl(bitrate: 8000000, cap: 16000000);
  // A UDP path that loses too much: the stream moves to TCP (7.2).
  final _lossy = LossyPath();
  bool _overTcp = false;
  int get _bitrate => _rate.bitrate;

  // Each frame's datagrams go out spread over part of a frame interval, not
  // in one burst (7.2), a keyframe no faster than the bitrate; the frames
  // behind it wait. _pumpTimer runs while some are waiting.
  PacedSender _pacer = PacedSender(maxQueuedFrames: 60);
  Timer? _pumpTimer;
  // When a keyframe was last asked of the encoder: one is big, and asking
  // again while it is still going out only floods the uplink.
  int _keyframeAt = -1000;

  // Per-second statistics for the viewer ($prefix.stats).
  final _clock = Stopwatch()..start();
  Timer? _statsTimer;
  int _statsAt = 0, _statsUnits = 0, _statsBytes = 0;

  StreamSubscription<CaptureUnit>? _auSub;
  final _changed = StreamController<void>.broadcast();
  Stream<void> get changed => _changed.stream;
  bool get sharing => state == HostState.sharing;
  String? get viewerName =>
      _viewer == null ? null : session.peers[_viewer]?.displayName;

  // Retransmit history: frame seq -> its datagrams, kept briefly for nacks.
  final _history = <int, List<Uint8List>>{};
  final _historyOrder = <int>[];

  final _rand = Random();

  void _notify() {
    if (!_changed.isClosed) _changed.add(null);
  }

  bool _onControl(String dev, Map<String, Object?> msg) {
    final t = msg['t'];
    if (t is! String) return false;
    // Our own video-channel messages (scr.* or cam.*).
    if (t.startsWith('$prefix.')) {
      switch (t.substring(prefix.length + 1)) {
        case 'request':
          _onRequest(dev, msg);
        case 'keyframe':
          if (_is(msg, 'session') && dev == _viewer) _keyframe();
        case 'nack':
          if (_is(msg, 'session') && dev == _viewer) _onNack(msg);
        case 'report':
          if (_is(msg, 'session') && dev == _viewer) _onReport(msg);
        case 'monitor':
          if (_is(msg, 'session') && dev == _viewer) {
            unawaited(_switchMonitor(_intf(msg, 'index')));
          }
        case 'control':
          if (_supportsControl && _is(msg, 'session') && dev == _viewer) {
            unawaited(_onControlRequest(dev, msg));
          }
        case 'stop':
          if (dev == _viewer &&
              (_is(msg, 'session') ||
                  (_session == 0 && _intf(msg, 'request') == _request))) {
            _teardown();
          }
        default:
          return false;
      }
      return true;
    }
    // Remote-control input (screen only); a camera has no input channel.
    if (!_supportsControl) return false;
    switch (t) {
      case 'in.mouse':
        if (_controlOn && dev == _viewer && _is(msg, 'session')) {
          final x = (msg['x'] is num ? (msg['x'] as num).toDouble() : 0.0);
          final y = (msg['y'] is num ? (msg['y'] as num).toDouble() : 0.0);
          final buttons = _intf(msg, 'buttons');
          input.pointer(x, y, buttons != 0);
        }
      case 'in.wheel':
        if (_controlOn && dev == _viewer && _is(msg, 'session')) {
          input.scroll(0.5, 0.5, _intf(msg, 'dx'), _intf(msg, 'dy'));
        }
      case 'in.key':
        if (_controlOn && dev == _viewer && _is(msg, 'session') &&
            msg['down'] == true) {
          input.key(_intf(msg, 'usage'));
        }
      case 'in.text':
        if (_controlOn && dev == _viewer && _is(msg, 'session') &&
            msg['text'] is String) {
          input.text(msg['text'] as String);
        }
      case 'in.release':
        if (_controlOn && dev == _viewer && _is(msg, 'session')) {
          input.release();
        }
      default:
        return false;
    }
    return true;
  }

  bool _is(Map<String, Object?> msg, String field) =>
      _session != 0 && _intf(msg, field) == _session;

  int _intf(Map<String, Object?> msg, String k) =>
      msg[k] is num ? (msg[k] as num).toInt() : 0;

  Future<void> _onRequest(String dev, Map<String, Object?> msg) async {
    final request = _intf(msg, 'request');
    if (request == 0) return;
    void err(String code) => session.sendControl(
        dev, {'t': '$prefix.err', 'request': request, 'code': code});

    if (!offered || !capture.supported) return err('forbidden');
    // Codec check.
    final codecs = msg['codecs'];
    if (codecs is List && !codecs.contains('h264')) return err('codec');
    // The current viewer asking again (a quality change, a retry) replaces its
    // own session instead of being refused as busy. Its stop usually arrives
    // just before and starts a teardown that is still running; wait for it.
    if (state == HostState.sharing && dev == _viewer) _teardown();
    final stopping = _stopping;
    if (stopping != null) await stopping;
    // Only one viewer at a time.
    if (state == HostState.sharing) return err('busy');
    // The peer must have proven identity and hold the view permission here.
    final perms = session.permissionsFor(dev);
    final peer = session.peers[dev];
    if (peer == null || peer.identityState != 'verified') return err('forbidden');
    if (!perms.contains(viewPerm)) return err('forbidden');

    // Consent, unless the peer holds the matching "direct" grant. A camera has
    // no direct grant (directPerm is null), so it always asks.
    if (directPerm == null || !perms.contains(directPerm!)) {
      session.sendControl(dev, {'t': '$prefix.wait', 'request': request});
      final ok = await askConsent(dev, peer.displayName,
          control: false, camera: prefix == 'cam');
      if (!ok) return err('denied');
      if (state == HostState.sharing) return err('busy');
    }

    // The OS capture-consent dialog (or the camera runtime permission).
    final granted = await capture.requestConsent();
    if (!granted) return err('denied');

    // Honour the viewer's requested quality, bounded by the source's own caps.
    var maxWidth = _intf(msg, 'maxWidth');
    if (maxWidth <= 0) maxWidth = 1920;
    if (maxWidthCap > 0) maxWidth = min(maxWidth, maxWidthCap);
    var maxFps = _intf(msg, 'maxFps');
    if (maxFps <= 0) maxFps = 60;
    if (maxFpsCap > 0) maxFps = min(maxFps, maxFpsCap);
    _fps = maxFps.clamp(1, 120);
    // The viewer may ask for less than this device allows, never more.
    final asked = _intf(msg, 'maxBitrate');
    final allowed = maxBitrateCap > 0 ? maxBitrateCap : 16000000;
    final cap = asked > 0 ? min(allowed, max(asked, BitrateControl.minBitrate)) : allowed;
    // Direct links start higher; relay/TCP lower (7.2). A phone's uplink
    // (often cellular) takes less than a desktop's: it starts at half of a
    // desktop's and climbs while reports stay clean.
    final path = session.node?.datagramPath(session.topicId, dev) ?? 0;
    _rate = BitrateControl(bitrate: min(cap, path == ucPathDirect ? 4000000 : 1500000), cap: cap);

    // The sources on offer (cameras); the viewer gets this list and may switch.
    final sources = await capture.sources();
    final wantMonitor = _intf(msg, 'monitor');
    _monitor = (wantMonitor >= 0 && wantMonitor < sources.length) ? wantMonitor : 0;
    if (sources.isNotEmpty) capture.selectSource(_monitor);

    // The size asked for bounds the long side: a portrait phone screen
    // (1220x2712) asked for at "1080p" is sent at most 1920 tall. Full size,
    // its keyframes are too big for a phone's uplink.
    final size = await capture.start(
      width: maxWidth,
      height: maxWidth, // the source keeps its own aspect
      fps: _fps,
      bitrate: _bitrate,
    );
    _width = size.width.toInt();
    _height = size.height.toInt();
    if (_width == 0 || _height == 0) {
      await capture.stop();
      return err('transport');
    }

    _viewer = dev;
    _request = request;
    _session = 1 + _rand.nextInt(0xFFFE); // nonzero u16
    _seq = 0;
    _pacer = PacedSender(maxQueuedFrames: 60);
    _keyframeAt = -1000;
    _lossy.reset();
    _overTcp = false;
    state = HostState.sharing;
    _controlOn = false;
    _history.clear();
    _historyOrder.clear();

    // Open the media datagram channel toward the viewer with the fallback the
    // current relay mode allows.
    session.node?.openDatagrams(session.topicId, dev, session.mediaFallback);

    session.sendControl(dev, {
      't': '$prefix.started',
      'request': request,
      'session': _session,
      'codec': 'h264',
      'width': _width,
      'height': _height,
      'fps': _fps,
      // The sources on offer, named, as the protocol's monitor list (one entry
      // "Screen" for a screen, the cameras for a camera) so the viewer can
      // build a picker. The caps let it bound its own quality choices.
      'monitors': sources.isEmpty
          ? [
              {'name': 'Screen', 'width': _width, 'height': _height}
            ]
          : [
              for (final s in sources) {'name': s}
            ],
      'monitor': _monitor,
      'maxWidth': maxWidthCap > 0 ? maxWidthCap : _width,
      'maxFps': maxFpsCap > 0 ? maxFpsCap : _fps,
      'control': false,
      'cursorEmbedded': true,
    });

    // An initial wantControl request is handled once sharing is up (screen).
    if (_supportsControl && msg['wantControl'] == true) {
      unawaited(_setControl(dev, request, true));
    }

    _auSub = capture.accessUnits().listen(_onAccessUnit);
    _statsAt = _clock.elapsedMilliseconds;
    _statsUnits = _statsBytes = 0;
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendStats());
    // The encoder's very first keyframe can be dropped while the media channel
    // is still opening; force fresh ones over the first second so the viewer
    // gets a complete reference promptly.
    for (final ms in [400, 800, 1500]) {
      Timer(Duration(milliseconds: ms), () {
        if (state == HostState.sharing && _viewer == dev) {
          capture.requestKeyframe();
        }
      });
    }
    _notify();
  }

  Future<void> _onControlRequest(String dev, Map<String, Object?> msg) =>
      _setControl(dev, _intf(msg, 'request'), msg['on'] == true);

  // Grants or drops remote control for the watching peer, with the same
  // rules/permission/consent gate as screen viewing (7.5).
  Future<void> _setControl(String dev, int request, bool on) async {
    void answer(bool granted, [String? detail]) => session.sendControl(dev, {
          't': 'scr.controlled',
          'session': _session,
          'request': request,
          'on': granted,
          if (detail != null) 'detail': detail,
        });

    if (!on) {
      _controlOn = false;
      input.release();
      answer(false);
      _notify();
      return;
    }
    final perms = session.permissionsFor(dev);
    if (!offerControl) return answer(false, 'This device does not offer remote control.');
    if (!await input.available()) {
      return answer(false, 'Remote control is not enabled on this device.');
    }
    if (!perms.contains(Perm.controlInput)) {
      return answer(false, 'Not allowed to control this device.');
    }
    if (!perms.contains(Perm.controlDirect)) {
      final name = session.peers[dev]?.displayName ?? 'A device';
      final ok = await askConsent(dev, name, control: true);
      if (!ok) return answer(false, 'The person at the device declined control.');
      if (state != HostState.sharing || _viewer != dev) return;
    }
    _controlOn = true;
    answer(true);
    _notify();
  }

  // Switches the camera being captured (cam.monitor) without ending the
  // session: restart the capture on the chosen source and tell the viewer.
  Future<void> _switchMonitor(int index) async {
    final dev = _viewer;
    if (dev == null || state != HostState.sharing) return;
    final sources = await capture.sources();
    if (index < 0 || index >= sources.length || index == _monitor) return;
    _monitor = index;
    capture.selectSource(index);
    await _auSub?.cancel();
    _auSub = null;
    await capture.stop();
    final size = await capture.start(
      width: _width > 0 ? _width : 1280,
      height: (_width > 0 ? _width : 1280) * 2,
      fps: _fps,
      bitrate: _bitrate,
    );
    if (size.width == 0 || _viewer != dev || state != HostState.sharing) {
      _teardown();
      await _stopping;
      return;
    }
    _width = size.width.toInt();
    _height = size.height.toInt();
    _auSub = capture.accessUnits().listen(_onAccessUnit);
    session.sendControl(dev, {
      't': '$prefix.monitorChanged',
      'session': _session,
      'index': _monitor,
      'width': _width,
      'height': _height,
    });
    Timer(const Duration(milliseconds: 300), () {
      if (state == HostState.sharing && _viewer == dev) _keyframe();
    });
    _notify();
  }

  static const int _payloadMax = 1084; // 1100-byte datagram minus 16-byte header

  void _onAccessUnit(CaptureUnit u) {
    final dev = _viewer;
    if (dev == null || state != HostState.sharing) return;
    final seq = _seq & 0xFFFFFFFF;
    _seq++;
    _statsUnits++;
    _statsBytes += u.bytes.length;
    final count = (u.bytes.length + _payloadMax - 1) ~/ _payloadMax;
    if (count == 0 || count > 0xFFFF) return;
    final ts = (u.ptsUs ~/ 1000) & 0xFFFFFFFF;
    final datagrams = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = i * _payloadMax;
      final end = min(start + _payloadMax, u.bytes.length);
      final dg = _packet(seq, i, count, u.keyframe, false, ts,
          Uint8List.sublistView(u.bytes, start, end));
      datagrams.add(dg);
    }
    _remember(seq, datagrams);
    // A frame that cannot be queued is lost: the next must be a keyframe.
    if (!_pacer.add(datagrams, _clock.elapsedMilliseconds,
        intervalMs: 1000 ~/ max(1, _fps), paceBps: max(500000, _bitrate), maxSpreadMs: 500)) {
      _keyframe();
    }
    _pump();
  }

  // Asks the encoder for a keyframe, at most once a second: the viewer asks
  // every 200 ms while it waits, and on a policed uplink (cellular) keyframes
  // that often are most of the traffic and get lost themselves.
  void _keyframe() {
    final now = _clock.elapsedMilliseconds;
    if (now - _keyframeAt < 1000) return;
    _keyframeAt = now;
    capture.requestKeyframe();
  }

  // Sends what is due, and comes back in a couple of milliseconds while
  // datagrams are still waiting.
  void _pump() {
    _pumpTimer?.cancel();
    _pumpTimer = null;
    final dev = _viewer;
    if (dev == null || state != HostState.sharing) return;
    if (!_pacer.pump(_clock.elapsedMilliseconds, (dg) => _send(dev, dg))) {
      _keyframe(); // stale frames were dropped
    }
    if (!_pacer.idle) _pumpTimer = Timer(const Duration(milliseconds: 2), _pump);
  }

  Uint8List _packet(int seq, int index, int count, bool keyframe,
      bool retransmit, int ts, Uint8List payload) {
    final dg = Uint8List(16 + payload.length);
    final bd = ByteData.sublistView(dg);
    dg[0] = videoKind; // 1 = screen video, 3 = camera video
    dg[1] = (keyframe ? 1 : 0) | (retransmit ? 2 : 0);
    bd.setUint16(2, _session);
    bd.setUint32(4, seq);
    bd.setUint16(8, index);
    bd.setUint16(10, count);
    bd.setUint32(12, ts);
    dg.setRange(16, 16 + payload.length, payload);
    return dg;
  }

  bool _send(String dev, Uint8List dg) {
    // Best effort; the viewer nacks anything the path dropped.
    return session.node?.sendDatagram(session.topicId, dev, dg) ?? false;
  }

  void _remember(int seq, List<Uint8List> datagrams) {
    _history[seq] = datagrams;
    _historyOrder.add(seq);
    // Keep roughly the last 500 ms, bounded to 16 frames (7.1).
    while (_historyOrder.length > 16) {
      _history.remove(_historyOrder.removeAt(0));
    }
  }

  void _onNack(Map<String, Object?> msg) {
    final dev = _viewer;
    if (dev == null) return;
    final frame = _intf(msg, 'frame');
    final dgs = _history[frame];
    if (dgs == null) return;
    final indexes = msg['indexes'];
    if (indexes is! List) return;
    for (final idx in indexes) {
      if (idx is num && idx.toInt() < dgs.length) {
        final original = dgs[idx.toInt()];
        // Re-send with the retransmission flag set.
        final copy = Uint8List.fromList(original);
        copy[1] = copy[1] | 2;
        _send(dev, copy);
      }
    }
  }

  // Rate control (7.2, BitrateControl): loss and rising delay ease it down,
  // clean reports raise it.
  void _onReport(Map<String, Object?> msg) {
    final received = _intf(msg, 'received'), lost = _intf(msg, 'lost');
    // UDP losing much of the stream for seconds (a mobile uplink policing
    // it): send over TCP from now on, late rather than lost, and start the
    // bitrate over from where a relayed path would.
    final dev = _viewer;
    if (!_overTcp && dev != null && _lossy.report(received: received, lost: lost)) {
      final path = session.node?.datagramPath(session.topicId, dev) ?? 0;
      if ((path == ucPathDirect || path == ucPathRelayed) &&
          (session.node?.sendDatagramsOverTcp(session.topicId, dev) ?? false)) {
        _overTcp = true;
        _rate = BitrateControl(bitrate: min(_rate.cap, max(_rate.bitrate, 1500000)), cap: _rate.cap);
        capture.setBitrate(_bitrate);
        _keyframe();
        return;
      }
    }
    final changed = _rate.report(
        received: received,
        lost: lost,
        trendMs: msg['owdTrendMs'] is num ? (msg['owdTrendMs'] as num).toDouble() : 0.0);
    if (changed != null) capture.setBitrate(changed);
  }

  // How the sending side keeps up, for the viewer's statistics.
  void _sendStats() {
    final dev = _viewer;
    if (dev == null || state != HostState.sharing) return;
    final now = _clock.elapsedMilliseconds;
    final span = max(1, now - _statsAt);
    session.sendControl(dev, {
      't': '$prefix.stats',
      'session': _session,
      'fps': _statsUnits * 1000 / span,
      'sentKbps': _statsBytes * 8 / span,
      'targetKbps': _bitrate ~/ 1000,
      'targetFps': _fps,
      'width': _width,
      'senderDrops': _pacer.dropped,
      'pipeline': 'Android MediaCodec',
    });
    _statsAt = now;
    _statsUnits = _statsBytes = 0;
  }

  /// Stops sharing (user pressed Stop, or the app is leaving the screen).
  Future<void> stop() async {
    final dev = _viewer;
    if (dev != null && _session != 0) {
      session.sendControl(dev, {'t': '$prefix.stop', 'session': _session});
    }
    _teardown();
    await _stopping;
  }

  // The teardown in progress, if any. It is async (closing the camera or the
  // capture takes a moment), so a request arriving meanwhile awaits it.
  Future<void>? _stopping;

  void _teardown() {
    _stopping ??= _teardownAsync().whenComplete(() => _stopping = null);
  }

  Future<void> _teardownAsync() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    _pacer.clear();
    await _auSub?.cancel();
    _auSub = null;
    if (_controlOn) {
      input.release();
      _controlOn = false;
    }
    if (state == HostState.sharing) {
      await capture.stop();
    }
    if (_viewer != null) {
      session.node?.closeDatagrams(session.topicId, _viewer!);
    }
    state = HostState.idle;
    _viewer = null;
    _session = 0;
    _request = 0;
    _history.clear();
    _historyOrder.clear();
    _notify();
  }

  Future<void> dispose() async {
    session.removeControlHandler(_onControl);
    _teardown();
    await _stopping;
    await _changed.close();
  }
}
