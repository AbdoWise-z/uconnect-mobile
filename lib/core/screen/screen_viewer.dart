// Viewer side of a screen-sharing session (docs/protocol.md section 7). The
// phone asks a peer to share its screen; the peer encodes H.264 and sends it
// as video datagrams, which this class reassembles into access units and hands
// to a platform decoder. It returns the feedback the protocol expects
// (scr.nack / scr.keyframe / scr.report) and forwards pointer and keyboard
// events to the peer as in.* control messages, which the peer applies.
//
// This runs the same handshake for screens (scr.*) and cameras (cam.*); the
// prefix and video datagram kind differ. It receives and decodes video and
// sends small JSON control messages; it does not itself act on the remote
// machine.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../session.dart';

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

class _Assembly {
  _Assembly(this.sequence, this.count, this.keyframe, this.captureMs);
  final int sequence;
  final int count;
  final bool keyframe;
  final int captureMs;
  final fragments = <int, Uint8List>{};
  int bytes = 0;
  bool nacked = false;
  late DateTime deadline;

  bool get complete => fragments.length == count;

  Uint8List assemble() {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      out.add(fragments[i]!);
    }
    return out.toBytes();
  }
}

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

  final _units = StreamController<VideoAccessUnit>.broadcast();
  final _cursorMoves = StreamController<CursorMove>.broadcast();
  final _cursorImages = StreamController<CursorImage>.broadcast();
  final _changed = StreamController<void>.broadcast();

  Stream<VideoAccessUnit> get units => _units.stream;
  Stream<CursorMove> get cursorMoves => _cursorMoves.stream;
  Stream<CursorImage> get cursorImages => _cursorImages.stream;
  Stream<void> get changed => _changed.stream;

  String get dev => _dev ?? '';
  int get sessionToken => _session;
  bool get active => state == ViewerState.active;

  // Reassembly state (7.1).
  final _assemblies = <int, _Assembly>{};
  int _nextDeliver = -1; // next sequence to deliver; -1 until a keyframe lands
  bool _gated = true; // deltas gated until a complete keyframe
  DateTime _lastKeyframeAsk = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _tick;

  // Report counters (7.2), reset each report.
  int _received = 0;
  int _lost = 0;
  int _late = 0;
  int _decodeMs = 0;
  Timer? _reportTimer;
  DateTime _lastUnitAt = DateTime.fromMillisecondsSinceEpoch(0);

  int _nextRequestId = 1;

  void _notify() {
    if (!_changed.isClosed) _changed.add(null);
  }

  String _t(String suffix) => '$prefix.$suffix';

  int get _videoKind => prefix == 'cam' ? 3 : 1;

  /// Report the decode time of the last access unit (ms); folded into the
  /// next scr.report so the sender can pace to the viewer.
  void reportDecodeMs(int ms) => _decodeMs = ms;

  /// Asks the peer to share its screen. The peer may ask its user first, in
  /// which case state becomes [ViewerState.waiting].
  ///
  /// The host scales and paces down to the maxWidth/maxFps we ask for
  /// (ScreenService honours them per viewer). The caller passes the quality the
  /// user picked; a lower one keeps playback smooth when the phone's decoder
  /// cannot keep up with a full-resolution desktop during motion.
  void request(String devId,
      {bool wantControl = false, int maxWidth = 1920, int maxFps = 60}) {
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
      'codecs': ['h264'],
    });
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
      session.sendControl(dev, {'t': _t('stop'), 'session': _session});
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
    _assemblies.clear();
    _nextDeliver = -1;
    _gated = true;
    _received = _lost = _late = _decodeMs = 0;
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
    // Open the media datagram channel with the fallback the relay mode allows.
    session.node?.openDatagrams(session.topicId, _dev!, session.mediaFallback);
    _reportTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _sendReport());
    _tick = Timer.periodic(const Duration(milliseconds: 15), (_) => _onTick());
    _notify();
  }

  int _int(Map<String, Object?> m, String k, int d) =>
      m[k] is num ? (m[k] as num).toInt() : d;

  void _onCursorImage(Map<String, Object?> msg) {
    if (!_is(msg, 'session', _session) || msg['png'] is! String) return;
    try {
      final png = base64Decode(msg['png'] as String);
      if (png.length <= 49 * 1024) {
        _cursorImages.add(CursorImage(
            png, _int(msg, 'hotspotX', 0), _int(msg, 'hotspotY', 0)));
      }
    } on FormatException {
      // a malformed cursor image is not worth ending the session over
    }
  }

  // --- video and cursor datagrams --------------------------------------------

  static const int _headerLen = 16;

  void _onDatagram(String dev, Uint8List d) {
    if (dev != _dev || state != ViewerState.active || d.isEmpty) return;
    final kind = d[0];
    if (kind == 2) {
      _onCursorMove(d);
      return;
    }
    if (kind != _videoKind || d.length <= _headerLen) return;
    final bd = ByteData.sublistView(d);
    final flags = d[1];
    final token = bd.getUint16(2);
    if (token != _session) return;
    final seq = bd.getUint32(4);
    final index = bd.getUint16(8);
    final count = bd.getUint16(10);
    final captureMs = bd.getUint32(12);
    if (count == 0 || index >= count || count > 4096) return;
    final payload = Uint8List.sublistView(d, _headerLen);
    // Non-final fragments are exactly 1084 bytes; a frame is bounded to 4 MiB.
    if (index != count - 1 && payload.length != 1084) return;
    if (count * 1084 > 4 * 1024 * 1024) return;
    final keyframe = (flags & 1) != 0;

    if (_nextDeliver >= 0 && _before(seq, _nextDeliver)) {
      _late++;
      return;
    }
    if (_gated && !keyframe && !_assemblies.containsKey(seq)) return;

    var a = _assemblies[seq];
    if (a == null) {
      if (_assemblies.length >= 8) _dropOldest();
      a = _Assembly(seq, count, keyframe, captureMs)
        ..deadline = DateTime.now()
            .add(Duration(milliseconds: 2 * (1000 ~/ fps) + 60));
      _assemblies[seq] = a;
    }
    if (a.count != count || a.keyframe != keyframe) return; // bad metadata
    if (a.fragments.containsKey(index)) return; // duplicates do not count
    a.fragments[index] = Uint8List.fromList(payload);
    a.bytes += payload.length;

    var buffered = 0;
    for (final x in _assemblies.values) {
      buffered += x.bytes;
    }
    if (buffered > 8 * 1024 * 1024) _dropOldest();
    _deliverReady();
  }

  bool _before(int a, int b) =>
      a != b && ((b - a) & 0xFFFFFFFF) < 0x80000000;

  void _dropOldest() {
    int? oldest;
    for (final seq in _assemblies.keys) {
      if (oldest == null || _before(seq, oldest)) oldest = seq;
    }
    if (oldest != null) {
      _assemblies.remove(oldest);
      _lost++;
    }
  }

  void _deliverReady() {
    while (true) {
      _Assembly? next;
      if (_nextDeliver >= 0 &&
          _assemblies[_nextDeliver] != null &&
          _assemblies[_nextDeliver]!.complete) {
        next = _assemblies[_nextDeliver];
      } else {
        // Nothing to deliver next-in-order: a complete keyframe may leapfrog a
        // lost reference, and the first delivery must be a keyframe.
        for (final a in _assemblies.values) {
          if (a.complete &&
              a.keyframe &&
              (_nextDeliver < 0 || !_before(a.sequence, _nextDeliver))) {
            if (next == null || _before(a.sequence, next.sequence)) next = a;
          }
        }
      }
      if (next == null) return;
      _assemblies.remove(next.sequence);
      _assemblies.removeWhere((seq, _) {
        if (_before(seq, next!.sequence)) {
          _lost++;
          return true;
        }
        return false;
      });
      _gated = false;
      _nextDeliver = (next.sequence + 1) & 0xFFFFFFFF;
      _received++;
      _lastUnitAt = DateTime.now();
      _units.add(VideoAccessUnit(
          next.sequence, next.keyframe, next.captureMs, next.assemble()));
    }
  }

  void _onTick() {
    if (state != ViewerState.active) return;
    final now = DateTime.now();
    final interval = (1000 ~/ fps).clamp(1, 1000);
    for (final a in _assemblies.values.toList()) {
      if (a.complete || !now.isAfter(a.deadline)) continue;
      if (!a.nacked && (!_gated || a.keyframe)) {
        a.nacked = true;
        final missing = <int>[
          for (var i = 0; i < a.count; i++)
            if (!a.fragments.containsKey(i)) i
        ];
        session.sendControl(_dev!, {
          't': _t('nack'),
          'session': _session,
          'frame': a.sequence,
          'indexes': missing,
        });
        a.deadline = now.add(Duration(milliseconds: interval.clamp(30, 1000)));
      } else {
        // A frame that still cannot complete is a lost reference: gate deltas
        // and ask for a fresh keyframe.
        _assemblies.remove(a.sequence);
        _lost++;
        _gated = true;
        _askKeyframe();
      }
    }
    // Gated with no keyframe in hand (e.g. the host's first keyframe was lost
    // while the media channel was still opening): keep asking for one. This is
    // rate limited to once per 200 ms inside _askKeyframe.
    if (_gated && _assemblies.isEmpty &&
        now.difference(_lastUnitAt) > const Duration(milliseconds: 300)) {
      _askKeyframe();
    }
    // No decoded picture for 8 s after start: tell the user (7.3).
    if (now.difference(_lastUnitAt) > const Duration(seconds: 8) &&
        error.isEmpty &&
        statusDetail.isEmpty) {
      statusDetail = 'Waiting for the screen…';
      _notify();
    }
  }

  void _askKeyframe() {
    final now = DateTime.now();
    if (now.difference(_lastKeyframeAsk) < const Duration(milliseconds: 200)) {
      return; // rate limited to once per 200 ms (7.1)
    }
    _lastKeyframeAsk = now;
    session.sendControl(
        _dev!, {'t': _t('keyframe'), 'session': _session});
  }

  void _sendReport() {
    if (state != ViewerState.active) return;
    session.sendControl(_dev!, {
      't': _t('report'),
      'session': _session,
      'received': _received,
      'lost': _lost,
      'late': _late,
      'jitterMs': 0,
      'owdTrendMs': 0,
      'decodeMs': _decodeMs,
    });
    _received = _lost = _late = 0;
  }

  void _onCursorMove(Uint8List d) {
    // [u8=2][u16 session][u32 seq][i32 x][i32 y][u8 visible], big endian.
    if (d.length < 16) return;
    final bd = ByteData.sublistView(d);
    if (bd.getUint16(1) != _session) return;
    final x = bd.getInt32(7);
    final y = bd.getInt32(11);
    final visible = d[15] != 0;
    _cursorMoves.add(CursorMove(x, y, visible));
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
    await _units.close();
    await _cursorMoves.close();
    await _cursorImages.close();
    await _changed.close();
  }
}
