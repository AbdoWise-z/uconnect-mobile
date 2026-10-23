// Host side of screen sharing (docs/protocol.md section 7): this device
// shares its screen to a peer that asks. It answers scr.request (after a
// permission check and, unless the peer holds screen.direct, a consent
// prompt), captures and encodes via CaptureController, and hands each access
// unit to a MediaSender, which cuts it into paced, repairable datagrams and
// reads the viewer's feedback datagrams back (the bandwidth estimate, repeats,
// keyframe requests). One viewer at a time in this version.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../permissions.dart';
import '../session.dart';
import '../../uconnect/uconnect.dart' show ucPathDirect, ucPathTcp;
import 'media_packet.dart';
import 'media_sender.dart';
import 'remote_input.dart';
import 'screen_capture.dart';

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
    session.addDatagramHandler(_onDatagram);
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
  int _frame = 0; // frame numbers, in capture order
  int _width = 0;
  int _height = 0;
  int _fps = 30;
  // The quality asked for (bounded by the caps) and the rung in use: the
  // bound on the long side the encoder is given, stepped down while the path
  // is thin (see _adaptQuality).
  int _maxWidth = 1920, _maxFps = 60, _askWidth = 1920;
  bool _resizing = false, _canResize = true;
  // The media session toward the viewer: pacing, repair, the rate estimate.
  MediaSender? _media;
  int _encoderBps = 0; // what the encoder was last told
  int _skipped = 0; // frames not sent because the queue was deep
  Timer? _pumpTimer; // sends what the pacing allows, every few milliseconds
  Timer? _controlTimer; // the encoder's rate and keyframes, every 200 ms
  static const int _pumpMs = 3;

  // Per-second statistics for the viewer ($prefix.stats).
  final _clock = Stopwatch()..start();
  Timer? _statsTimer;
  int _statsAt = 0, _statsUnits = 0, _statsBytes = 0, _statsSkipped = 0;

  StreamSubscription<CaptureUnit>? _auSub;
  final _changed = StreamController<void>.broadcast();
  Stream<void> get changed => _changed.stream;
  bool get sharing => state == HostState.sharing;
  String? get viewerName =>
      _viewer == null ? null : session.peers[_viewer]?.displayName;

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
          if (_is(msg, 'session') && dev == _viewer) _media?.awaitKey = true;
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

  // The viewer's feedback comes back on the media channel (7.2).
  void _onDatagram(String dev, Uint8List d) {
    final media = _media;
    if (media == null || dev != _viewer || d.length < 2 || d[0] != videoKind) return;
    if (packetType(d) != PacketType.feedback) return;
    media.onFeedback(d, _clock.elapsedMilliseconds);
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
    _fps = _maxFps = maxFps.clamp(1, 120);
    _maxWidth = _askWidth = maxWidth;
    _canResize = true;
    // The viewer may ask for less than this device allows, never more.
    final asked = _intf(msg, 'maxBitrate');
    final allowed = maxBitrateCap > 0 ? maxBitrateCap : 16000000;
    final cap = asked > 0 ? min(allowed, max(asked, minBitrate)) : allowed;
    // The estimate starts modestly and climbs as the path proves itself (7.2);
    // a direct link a little higher. A phone's uplink is often cellular.
    final path = session.node?.datagramPath(session.topicId, dev) ?? 0;
    final token = 1 + _rand.nextInt(0xFFFE); // nonzero u16
    final media = MediaSender(
      kind: videoKind,
      session: token,
      startBps: min(cap, path == ucPathDirect ? 3000000 : 1500000),
      maxBps: cap,
      fps: _fps,
      reliable: path == ucPathTcp,
    );

    // The sources on offer (cameras); the viewer gets this list and may switch.
    final sources = await capture.sources();
    final wantMonitor = _intf(msg, 'monitor');
    _monitor = (wantMonitor >= 0 && wantMonitor < sources.length) ? wantMonitor : 0;
    if (sources.isNotEmpty) capture.selectSource(_monitor);

    // The size asked for bounds the long side: a portrait phone screen
    // (1220x2712) asked for at "1080p" is sent at most 1920 tall. Full size,
    // its keyframes are too big for a phone's uplink.
    _encoderBps = media.encoderBps;
    final size = await capture.start(
      width: maxWidth,
      height: maxWidth, // the source keeps its own aspect
      fps: _fps,
      bitrate: _encoderBps,
    );
    _width = size.width.toInt();
    _height = size.height.toInt();
    if (_width == 0 || _height == 0) {
      await capture.stop();
      return err('transport');
    }

    _viewer = dev;
    _request = request;
    _session = token;
    _media = media;
    _frame = 0;
    _skipped = 0;
    state = HostState.sharing;
    _controlOn = false;

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
    _statsUnits = _statsBytes = _statsSkipped = 0;
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendStats());
    _pumpTimer?.cancel();
    _pumpTimer = Timer.periodic(const Duration(milliseconds: _pumpMs), (_) => _pump());
    _controlTimer?.cancel();
    _controlTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _steer());
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
    // What waits is of the old source; the new one starts at its keyframe.
    _media?.dropQueued();
    final size = await capture.start(
      width: _width > 0 ? _width : 1280,
      height: (_width > 0 ? _width : 1280) * 2,
      fps: _fps,
      bitrate: _encoderBps,
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
    _notify();
  }

  void _onAccessUnit(CaptureUnit u) {
    final media = _media;
    if (media == null || state != HostState.sharing) return;
    _statsUnits++;
    _statsBytes += u.bytes.length;
    final number = _frame & 0xFFFFFFFF;
    _frame++;
    // The queue is deep (the encoder put out more than the path takes): a
    // frame sent now would only arrive late. The encoder cannot skip a
    // capture, so the frame is dropped here and, as the ones after it would
    // be useless without it, the sender waits for a keyframe (asked for below).
    if (!u.keyframe && media.shouldSkipCapture()) {
      _skipped++;
      _statsSkipped++;
      media.awaitKey = true;
      return;
    }
    final frame = EncodedFrame(_session, number, (u.ptsUs ~/ 1000) & 0xFFFFFFFF, u.keyframe, u.bytes);
    media.enqueue(frame);
    _pump();
  }

  // Sends what the pacing allows.
  void _pump() {
    final media = _media;
    final dev = _viewer;
    if (media == null || dev == null || state != HostState.sharing) return;
    final now = _clock.elapsedMilliseconds;
    media.pump(now, (dg) => session.node?.sendDatagram(session.topicId, dev, dg) ?? false);
    if (media.takeKeyframeWanted(now)) capture.requestKeyframe();
  }

  // The encoder follows the estimate (less the repair packets' share), and
  // the sender learns whether the path is TCP (the channel fell back to it).
  void _steer() {
    final media = _media;
    final dev = _viewer;
    if (media == null || dev == null || state != HostState.sharing) return;
    media.reliable = (session.node?.datagramPath(session.topicId, dev) ?? 0) == ucPathTcp;
    final bps = media.encoderBps;
    if ((bps - _encoderBps).abs() * 10 > _encoderBps) {
      _encoderBps = bps;
      capture.setBitrate(bps);
    }
    _adaptQuality(media);
  }

  // The quality ladder (as the desktop's ScreenService::adaptQuality): the
  // bitrate the path allows buys so many pixels and frames for a clean
  // picture; down a rung at a time and up again only with room to spare
  // (each change rebuilds the encoder, which starts over with a keyframe).
  // Stepping down is only for a path that has shown its limit, and only while
  // the source asks for more than it gets: a simple picture needing little is
  // not a slow path.
  static const _rungs = [3840, 2560, 1920, 1280, 854];
  static const _needs = [8000000, 4000000, 2000000, 800000, 0]; // at 30 fps

  void _adaptQuality(MediaSender media) {
    if (_resizing || !_canResize) return;
    final bps = media.encoderBps;
    final atFps = (_maxFps / 30).clamp(0.5, 4.0);
    final down = media.pathLimited && !media.applicationLimited;
    // Frame rate first: under about half a megabit even the smallest picture
    // needs fewer frames to stay clean.
    var fps = _maxFps;
    if (down && bps < 250000) {
      fps = min(fps, 10);
    } else if (down && (bps < 400000 || (_fps <= 15 && bps < 520000))) {
      fps = min(fps, 15);
    } else if (!down && _fps < _maxFps && bps < 520000) {
      fps = _fps; // no room yet to go back up
    }
    var width = _askWidth;
    var rung = 0;
    while (rung < 4 && _rungs[rung] > _maxWidth) {
      rung++;
    }
    var current = 0;
    while (current < 4 && _rungs[current] > width) {
      current++;
    }
    final scale = fps >= 30 ? atFps : 0.6;
    if (down && bps < _needs[current] * scale * 0.8 && current < 4) {
      width = _rungs[current + 1]; // down a rung
    } else if (current > rung && bps > _needs[current - 1] * scale * 1.3) {
      width = _rungs[current - 1]; // up a rung
    }
    width = min(width, _maxWidth);
    if (width != _askWidth || fps != _fps) unawaited(_resize(width, fps));
  }

  Future<void> _resize(int width, int fps) async {
    final dev = _viewer;
    final media = _media;
    if (dev == null || media == null) return;
    _resizing = true;
    try {
      final size = await capture.resize(width: width, fps: fps);
      if (_viewer != dev || _media != media) return; // another session by now
      if (size.width == 0) {
        _canResize = false; // the source cannot (a camera): its quality stays
        return;
      }
      _askWidth = width;
      _fps = fps;
      media.fps = fps;
      _width = size.width.toInt();
      _height = size.height.toInt();
      _notify();
    } finally {
      _resizing = false;
    }
  }

  // How the sending side keeps up, for the viewer's statistics.
  void _sendStats() {
    final dev = _viewer;
    final media = _media;
    if (dev == null || media == null || state != HostState.sharing) return;
    final now = _clock.elapsedMilliseconds;
    final span = max(1, now - _statsAt);
    session.sendControl(dev, {
      't': '$prefix.stats',
      'session': _session,
      'fps': _statsUnits * 1000 / span,
      'sentKbps': media.sendBps / 1000,
      'encodedKbps': _statsBytes * 8 / span,
      'targetKbps': media.targetBps / 1000,
      'receiveKbps': media.receiveBps / 1000,
      'targetFps': _fps,
      'width': _width,
      'dropped': _statsSkipped * 1000 / span,
      'senderDrops': _skipped + media.dropped,
      'transport': media.reliable ? 'tcp' : 'udp',
      'lagMs': media.lagMs,
      'rttMs': media.rttMs,
      'lossPct': media.lossRate * 100,
      'fec': media.fecGroup,
      'repeats': media.retransmitted,
      'estimator': media.estimatorState,
      'pipeline': 'Android MediaCodec',
    });
    _statsAt = now;
    _statsUnits = _statsBytes = _statsSkipped = 0;
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
    _controlTimer?.cancel();
    _controlTimer = null;
    _media = null;
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
    _notify();
  }

  Future<void> dispose() async {
    session.removeControlHandler(_onControl);
    _teardown();
    await _stopping;
    await _changed.close();
  }
}
