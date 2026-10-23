// Viewer side of a screen-sharing session (docs/protocol.md section 7). The
// phone asks a peer to share its screen; the peer encodes H.264 and sends it
// as media datagrams, which a MediaReceiver reassembles (repairing and asking
// again for what was lost) into access units this class hands to a platform
// decoder. It sends the receiver's feedback datagrams back every few tens of
// milliseconds and forwards pointer and keyboard events to the peer as in.*
// control messages, which the peer applies.
//
// This runs the same handshake for screens (scr.*) and cameras (cam.*); the
// prefix and video datagram kind differ. It receives and decodes video and
// sends small JSON control messages; it does not itself act on the remote
// machine.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../session.dart';
import 'media_packet.dart';
import 'media_receiver.dart';

/// One complete, in-order H.264 access unit for the decoder.
class VideoAccessUnit {
  VideoAccessUnit(this.sequence, this.keyframe, this.captureMs, this.bytes);
  final int sequence;
  final bool keyframe;
  final int captureMs;
  final Uint8List bytes;
}

class CursorMove {
  CursorMove(this.x, this.y, this.visible);
  final int x;
  final int y;
  final bool visible;
}

class CursorImage {
  CursorImage(this.png, this.hotspotX, this.hotspotY);
  final Uint8List png;
  final int hotspotX;
  final int hotspotY;
}

enum ViewerState { idle, requesting, waiting, active, stopped, failed }

/// Pointer button bits, matching the protocol's left/right/middle = 1/2/4.
class MouseButton {
  static const left = 1;
  static const right = 2;
  static const middle = 4;
}

class ScreenViewer {
  ScreenViewer(this.session, {this.prefix = 'scr'}) {
    session.addControlHandler(_onControl);
    session.addDatagramHandler(_onDatagram);
    session.addPeerStateHandler((dev, state) {
      if (dev == _dev && (state == 4 || state == 5)) {
        _fail('The device disconnected.');
      }
    });
  }

  final Session session;

  /// 'scr' for a screen, 'cam' for a camera: the handshakes are identical
  /// bar the message prefix and the video datagram kind (1 vs 3).
  final String prefix;

  ViewerState state = ViewerState.idle;
  String error = '';
  String statusDetail = '';
  String? _dev;
  int _request = 0;
  int _session = 0;
  int width = 0;
  int height = 0;
  int fps = 30;
  int monitors = 1;
  int monitor = 0;
  List<String> cameras = const []; // camera names the host offers (cam only)
  int srcMaxWidth = 0; // the source's quality caps, for bounding our request
  int srcMaxFps = 0;
  bool controlOffered = false; // the session was started with control
  bool controlOn = false; // control is currently granted to us
  String controlDetail = '';
  bool cursorEmbedded = false;

  // The host's monitors, as sent in scr.started, kept for their native pixel
  // sizes: separate cursor-position datagrams are in those pixels, which can
  // differ from the (possibly capped) encoded `width`/`height`.
  List<Map<String, Object?>> _monitorInfo = const [];

  /// Width of the coordinate space the cursor datagrams use for the monitor
  /// currently shown — its native width, falling back to the encoded width.
  int get cursorSpaceWidth {
    if (monitor >= 0 && monitor < _monitorInfo.length) {
      final w = _monitorInfo[monitor]['width'];
      if (w is num && w > 0) return w.toInt();
    }
    return width;
  }

  int get cursorSpaceHeight {
    if (monitor >= 0 && monitor < _monitorInfo.length) {
      final h = _monitorInfo[monitor]['height'];
      if (h is num && h > 0) return h.toInt();
    }
    return height;
  }

  final _units = StreamController<VideoAccessUnit>.broadcast();
  final _cursorMoves = StreamController<CursorMove>.broadcast();
  final _cursorImages = StreamController<CursorImage>.broadcast();
  final _changed = StreamController<void>.broadcast();

  // The last cursor shape and position seen. These broadcast streams do not
  // buffer, and the host sends the shape only when it changes, so a late
  // subscriber (the overlay is built after the session starts) would miss it.
  // The overlay seeds itself from these.
  CursorImage? lastCursorImage;
  CursorMove? lastCursorMove;

  Stream<VideoAccessUnit> get units => _units.stream;
  Stream<CursorMove> get cursorMoves => _cursorMoves.stream;
  Stream<CursorImage> get cursorImages => _cursorImages.stream;
  Stream<void> get changed => _changed.stream;

  String get dev => _dev ?? '';
  int get sessionToken => _session;
  bool get active => state == ViewerState.active;

  // The media session (7.1, 7.2): reassembly, repair, feedback.
  MediaReceiver? _media;
  Timer? _tick;
  // Offset so the clock is never near zero: the feedback reference time is 16 s before now.
  final _clock = Stopwatch()..start();
  int get _now => _clock.elapsedMilliseconds + 60000;

  // Counters for the overlay, reset each second.
  int _frames = 0;
  int _packets = 0;
  int _decodeMs = 0;
  int _bytes = 0;

  /// The playout delay the decoder holds frames for, reported to the host.
  int playoutMs = 0;

  /// The playout delay the network calls for: the jitter and the time gaps
  /// take to fill, raised at once and lowered slowly (the view applies it
  /// when the buffer setting is "automatic").
  int autoPlayoutMs = 100;
  int _autoAt = 0;

  /// What the last second looked like, for the statistics overlay: frames
  /// completed and their bitrate, loss, jitter, and what the repair packets
  /// and repeats recovered.
  double unitsPerSecond = 0, kbps = 0, lossPct = 0;
  ReceiverStats lastSecond = ReceiverStats();
  double get jitterMs => _media?.jitterMs ?? 0;

  /// The host's own statistics (its $prefix.stats), empty until it sends any.
  Map<String, Object?> hostStats = const {};
  Timer? _reportTimer;
  DateTime _lastUnitAt = DateTime.fromMillisecondsSinceEpoch(0);

  int _nextRequestId = 1;

  void _notify() {
    if (!_changed.isClosed) _changed.add(null);
  }

  String _t(String suffix) => '$prefix.$suffix';

  int get _videoKind => prefix == 'cam' ? 3 : 1;

  /// Report the decode time of the last access unit (ms); folded into the
  /// next feedback so the sender can pace to the viewer.
  void reportDecodeMs(int ms) => _decodeMs = ms;

  /// Drops what is being assembled and waits for a keyframe (the decoder
  /// was restarted, or lost its way).
  void restartFromKeyframe() => _media?.restartFromKeyframe();

  /// Asks the peer to share its screen. The peer may ask its user first, in
  /// which case state becomes [ViewerState.waiting].
  ///
  /// The host scales and paces down to the maxWidth/maxFps we ask for
  /// (ScreenService honours them per viewer). The caller passes the quality the
  /// user picked; a lower one keeps playback smooth when the phone's decoder
  /// cannot keep up with a full-resolution desktop during motion.
  void request(String devId,
      {bool wantControl = false,
      int maxWidth = 1920,
      int maxFps = 60,
      int maxBitrate = 0}) {
    stop();
    _dev = devId;
    _request = _nextRequestId++;
    state = ViewerState.requesting;
    error = '';
    statusDetail = '';
    session.sendControl(devId, {
      't': _t('request'),
      'request': _request,
      'wantControl': wantControl,
      'maxWidth': maxWidth,
      'maxFps': maxFps,
      if (maxBitrate > 0) 'maxBitrate': maxBitrate,
      'codecs': ['h264'],
    });
    hostStats = const {};
    // A pending request expires in 35 s (7.3).
    Timer(const Duration(seconds: 35), () {
      if (_session == 0 &&
          (state == ViewerState.requesting || state == ViewerState.waiting)) {
        _fail('No answer to the request.');
      }
    });
    _notify();
  }

  void stop() {
    final dev = _dev;
    if (dev != null && _session != 0) {
      // Name the request as well as the session: the host tells a viewer's stop
      // from a host's by the presence of a request id, and only then drops our
      // viewer slot. Without it a re-request (e.g. a quality change) is refused
      // as "busy" because our previous slot is still counted.
      session.sendControl(
          dev, {'t': _t('stop'), 'session': _session, 'request': _request});
    } else if (dev != null && _request != 0 && state != ViewerState.idle) {
      session.sendControl(
          dev, {'t': _t('stop'), 'session': 0, 'request': _request});
    }
    _teardown();
    if (state != ViewerState.failed) state = ViewerState.stopped;
    _notify();
  }

  void _teardown() {
    _reportTimer?.cancel();
    _reportTimer = null;
    _tick?.cancel();
    _tick = null;
    _media = null;
    _frames = _packets = _decodeMs = _bytes = 0;
    if (_dev != null && _session != 0) {
      session.node?.closeDatagrams(session.topicId, _dev!);
    }
    _session = 0;
    _request = 0;
    controlOn = false;
  }

  void _fail(String why) {
    if (state == ViewerState.idle || state == ViewerState.stopped) return;
    _teardown();
    state = ViewerState.failed;
    error = why;
    _notify();
  }

  // --- control-channel messages ----------------------------------------------

  bool _onControl(String dev, Map<String, Object?> msg) {
    final t = msg['t'];
    if (t is! String || !t.startsWith('$prefix.')) return false;
    if (dev != _dev) return true; // not our host; consumed, ignored
    switch (t.substring(prefix.length + 1)) {
      case 'wait':
        if (_is(msg, 'request', _request) && state == ViewerState.requesting) {
          state = ViewerState.waiting;
          _notify();
        }
      case 'err':
        if (_is(msg, 'request', _request) && _session == 0) {
          final code = msg['code'] is String ? msg['code'] as String : 'error';
          _fail(switch (code) {
            'forbidden' => 'The device has not granted screen viewing.',
            'busy' => 'The device is busy with other viewers.',
            'denied' => 'The person at the device declined.',
            'codec' => 'No codec in common.',
            'transport' => 'The media channel could not open.',
            _ => 'The request failed ($code).',
          });
        }
      case 'started':
        _onStarted(msg);
      case 'controlled':
        if (_is(msg, 'session', _session)) {
          controlOn = msg['on'] == true;
          controlDetail =
              msg['detail'] is String ? msg['detail'] as String : '';
          _notify();
        }
      case 'monitorChanged':
        if (_is(msg, 'session', _session) && msg['index'] is num) {
          monitor = (msg['index'] as num).toInt();
          if (msg['width'] is num) width = (msg['width'] as num).toInt();
          if (msg['height'] is num) height = (msg['height'] as num).toInt();
          _notify();
        }
      case 'pipeline':
        if (_is(msg, 'session', _session)) {
          cursorEmbedded = msg['cursorEmbedded'] == true;
          _notify();
        }
      case 'cursor':
        _onCursorImage(msg);
      case 'stats':
        if (_is(msg, 'session', _session)) {
          hostStats = Map<String, Object?>.from(msg);
          _notify();
        }
      case 'status':
        if (_is(msg, 'session', _session)) {
          statusDetail = msg['detail'] is String ? msg['detail'] as String : '';
          _notify();
        }
      case 'error':
        if (_is(msg, 'session', _session)) {
          _fail(msg['detail'] is String
              ? msg['detail'] as String
              : 'The host reported an error.');
        }
      case 'stop':
        if (_is(msg, 'session', _session) ||
            (_session == 0 && _is(msg, 'request', _request))) {
          _teardown();
          state = ViewerState.stopped;
          _notify();
        }
    }
    return true;
  }

  bool _is(Map<String, Object?> msg, String field, int value) =>
      value != 0 && msg[field] is num && (msg[field] as num).toInt() == value;

  void _onStarted(Map<String, Object?> msg) {
    if (!_is(msg, 'request', _request) || _session != 0) return;
    final token = msg['session'] is num ? (msg['session'] as num).toInt() : 0;
    if (token == 0) return;
    _session = token;
    width = _int(msg, 'width', 0);
    height = _int(msg, 'height', 0);
    fps = _int(msg, 'fps', 30).clamp(1, 240);
    // The host's source list, named (the protocol's monitor list). For a
    // camera these are the cameras on offer; the viewer picks one.
    final mons = msg['monitors'];
    cameras = [
      if (mons is List)
        for (final m in mons)
          if (m is Map && m['name'] is String) m['name'] as String
    ];
    _monitorInfo = [
      if (mons is List)
        for (final m in mons)
          if (m is Map) m.map((k, v) => MapEntry(k.toString(), v))
    ];
    monitors = mons is List ? mons.length : _int(msg, 'monitors', 1);
    monitor = _int(msg, 'monitor', 0);
    srcMaxWidth = _int(msg, 'maxWidth', 0);
    srcMaxFps = _int(msg, 'maxFps', 0);
    controlOffered = msg['control'] == true;
    controlOn = msg['control'] == true;
    controlDetail =
        msg['controlDetail'] is String ? msg['controlDetail'] as String : '';
    cursorEmbedded = msg['cursorEmbedded'] == true;
    state = ViewerState.active;
    _lastUnitAt = DateTime.now();
    _media = MediaReceiver(session: token, kind: _videoKind, fps: fps);
    // Open the media datagram channel with the fallback the relay mode allows.
    session.node?.openDatagrams(session.topicId, _dev!, session.mediaFallback);
    _reportTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _everySecond());
    _tick = Timer.periodic(const Duration(milliseconds: 10), (_) => _onTick());
    _notify();
  }

  int _int(Map<String, Object?> m, String k, int d) =>
      m[k] is num ? (m[k] as num).toInt() : d;

  void _onCursorImage(Map<String, Object?> msg) {
    if (!_is(msg, 'session', _session) || msg['png'] is! String) return;
    try {
      final png = base64Decode(msg['png'] as String);
      if (png.length <= 49 * 1024) {
        final image = CursorImage(
            png, _int(msg, 'hotspotX', 0), _int(msg, 'hotspotY', 0));
        lastCursorImage = image;
        _cursorImages.add(image);
      }
    } on FormatException {
      // a malformed cursor image is not worth ending the session over
    }
  }

  // --- video and cursor datagrams --------------------------------------------

  void _onDatagram(String dev, Uint8List d) {
    final media = _media;
    if (media == null || dev != _dev || state != ViewerState.active || d.isEmpty) return;
    final kind = d[0];
    if (kind == 2) {
      _onCursorMove(d);
      return;
    }
    if (kind != _videoKind || packetType(d) == PacketType.feedback) return;
    _bytes += d.length;
    _packets++;
    final now = _now;
    final frames = media.receive(d, now);
    for (final f in frames) {
      _frames++;
      _units.add(VideoAccessUnit(f.number, f.keyframe, f.captureMs, f.bytes));
    }
    if (frames.isNotEmpty) _lastUnitAt = DateTime.now();
    // Something arrived that a keyframe is now wanted for (a reference was
    // lost): the word goes out at once rather than at the next interval.
    if (media.feedbackDue(now)) _sendFeedback(media, now);
  }

  void _onTick() {
    final media = _media;
    if (media == null || state != ViewerState.active) return;
    final now = _now;
    media.expire(now);
    if (media.feedbackDue(now)) _sendFeedback(media, now);
    if (now - _autoAt >= 250) {
      _autoAt = now;
      final want = media.suggestedPlayoutMs();
      autoPlayoutMs = want > autoPlayoutMs ? want : max(want, autoPlayoutMs - 5);
    }
    // No decoded picture for 8 s after start: tell the user (7.3).
    if (DateTime.now().difference(_lastUnitAt) > const Duration(seconds: 8) &&
        error.isEmpty &&
        statusDetail.isEmpty) {
      statusDetail = 'Waiting for the screen…';
      _notify();
    }
  }

  // Feedback goes back on the media channel (7.2): what arrived and when,
  // what to send again, whether a keyframe is wanted.
  void _sendFeedback(MediaReceiver media, int now) {
    final dev = _dev;
    if (dev == null) return;
    final ok = session.node?.sendDatagram(
            session.topicId, dev, media.takeFeedback(now, playoutMs, _decodeMs.toDouble())) ??
        false;
    if (ok != _feedbackSent || now - _feedbackLogMs > 5000) {
      _feedbackSent = ok;
      _feedbackLogMs = now;
      debugPrint('[screen viewer] feedback ${ok ? 'sent' : 'refused'}, media path ${session.node?.datagramPath(session.topicId, dev)}');
    }
  }

  bool _feedbackSent = false;
  int _feedbackLogMs = -100000;

  // Once a second: the overlay's figures.
  void _everySecond() {
    final media = _media;
    if (media == null || state != ViewerState.active) return;
    lastSecond = media.report();
    unitsPerSecond = _frames.toDouble();
    kbps = _bytes * 8 / 1000;
    final lost = lastSecond.lost;
    lossPct = _packets + lost == 0 ? 0 : lost * 100 / (_packets + lost);
    _frames = _packets = _bytes = 0;
    _notify();
  }

  void _onCursorMove(Uint8List d) {
    // [u8=2][u16 session][u32 seq][i32 x][i32 y][u8 visible], big endian.
    if (d.length < 16) return;
    final bd = ByteData.sublistView(d);
    if (bd.getUint16(1) != _session) return;
    final x = bd.getInt32(7);
    final y = bd.getInt32(11);
    final visible = d[15] != 0;
    final move = CursorMove(x, y, visible);
    lastCursorMove = move;
    _cursorMoves.add(move);
  }

  // --- control the viewer sends to the host ----------------------------------
  // These are JSON messages the peer applies on its own machine; the phone
  // only sends them. Each carries the session token.

  /// Asks for (or drops) control during a view session.
  void requestControl(bool on) {
    if (_session == 0) return;
    session.sendControl(_dev!, {
      't': _t('control'),
      'session': _session,
      'request': _request,
      'on': on,
    });
  }

  /// Switches which camera the host captures (cam.monitor); index into
  /// [cameras].
  void selectMonitor(int index) {
    if (_session == 0 || index == monitor) return;
    session.sendControl(
        _dev!, {'t': _t('monitor'), 'session': _session, 'index': index});
  }

  /// Pointer position in normalized monitor coordinates (0..1), with the
  /// pressed-button bitmask.
  void sendPointer(double nx, double ny, int buttons) {
    if (_session == 0 || !controlOn) return;
    session.sendControl(_dev!, {
      't': 'in.mouse',
      'session': _session,
      'x': nx.clamp(0.0, 1.0),
      'y': ny.clamp(0.0, 1.0),
      'buttons': buttons,
    });
  }

  void sendWheel(int dx, int dy) {
    if (_session == 0 || !controlOn) return;
    session.sendControl(
        _dev!, {'t': 'in.wheel', 'session': _session, 'dx': dx, 'dy': dy});
  }

  /// A key by USB HID usage code (keyboard page), pressed or released.
  void sendKey(int usage, bool down) {
    if (_session == 0 || !controlOn) return;
    session.sendControl(_dev!,
        {'t': 'in.key', 'session': _session, 'usage': usage, 'down': down});
  }

  /// Typed text (at most 256 UTF-16 units per message, per the protocol).
  void sendText(String text) {
    if (_session == 0 || !controlOn || text.isEmpty) return;
    final chunk = text.length > 256 ? text.substring(0, 256) : text;
    session.sendControl(
        _dev!, {'t': 'in.text', 'session': _session, 'text': chunk});
  }

  /// Releases everything held; sent on focus loss or when leaving the view.
  void releaseInput() {
    if (_session == 0) return;
    session.sendControl(_dev!, {'t': 'in.release', 'session': _session});
  }

  Future<void> dispose() async {
    stop();
    session.removeControlHandler(_onControl);
    await _units.close();
    await _cursorMoves.close();
    await _cursorImages.close();
    await _changed.close();
  }
}
