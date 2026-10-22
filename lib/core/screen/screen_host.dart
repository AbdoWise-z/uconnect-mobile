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
import '../../uconnect/uconnect.dart' show ucPathDirect;
import 'remote_input.dart';
import 'screen_capture.dart';

enum HostState { idle, sharing }

/// Asks the user to allow a peer to view this screen (or, with `control: true`,
/// to also control it). Return true to allow.
typedef ConsentAsk = Future<bool> Function(String dev, String name,
    {bool control});

class ScreenHost {
  ScreenHost(this.session, this.capture, this.input,
      {required this.askConsent}) {
    session.addControlHandler(_onControl);
    session.addPeerStateHandler((dev, state) {
      if (dev == _viewer && (state == 4 || state == 5)) _teardown();
    });
  }

  final Session session;
  final CaptureController capture;
  final RemoteInput input;
  final ConsentAsk askConsent;

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
  int _bitrate = 4000000;

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
    switch (t) {
      case 'scr.request':
        _onRequest(dev, msg);
      case 'scr.keyframe':
        if (_is(msg, 'session') && dev == _viewer) capture.requestKeyframe();
      case 'scr.nack':
        if (_is(msg, 'session') && dev == _viewer) _onNack(msg);
      case 'scr.report':
        if (_is(msg, 'session') && dev == _viewer) _onReport(msg);
      case 'scr.control':
        if (_is(msg, 'session') && dev == _viewer) {
          unawaited(_onControlRequest(dev, msg));
        }
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
      case 'scr.stop':
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

  bool _is(Map<String, Object?> msg, String field) =>
      _session != 0 && _intf(msg, field) == _session;

  int _intf(Map<String, Object?> msg, String k) =>
      msg[k] is num ? (msg[k] as num).toInt() : 0;

  Future<void> _onRequest(String dev, Map<String, Object?> msg) async {
    final request = _intf(msg, 'request');
    if (request == 0) return;
    void err(String code) => session.sendControl(
        dev, {'t': 'scr.err', 'request': request, 'code': code});

    if (!offered || !capture.supported) return err('forbidden');
    // Codec check.
    final codecs = msg['codecs'];
    if (codecs is List && !codecs.contains('h264')) return err('codec');
    // Only one viewer at a time.
    if (state == HostState.sharing) return err('busy');
    // The peer must have proven identity and hold screen.view here.
    final perms = session.permissionsFor(dev);
    final peer = session.peers[dev];
    if (peer == null || peer.identityState != 'verified') return err('forbidden');
    if (!perms.contains(Perm.screenView)) return err('forbidden');

    // Consent, unless the peer holds screen.direct.
    if (!perms.contains(Perm.screenDirect)) {
      session.sendControl(dev, {'t': 'scr.wait', 'request': request});
      final ok = await askConsent(dev, peer.displayName, control: false);
      if (!ok) return err('denied');
      if (state == HostState.sharing) return err('busy');
    }

    // The OS capture-consent dialog.
    final granted = await capture.requestConsent();
    if (!granted) return err('denied');

    final maxWidth = _intf(msg, 'maxWidth');
    final maxFps = _intf(msg, 'maxFps');
    _fps = (maxFps > 0 ? maxFps : 30).clamp(15, 60);
    // Direct links get more; relay/TCP start lower (7.2).
    final path = session.node?.datagramPath(session.topicId, dev) ?? 0;
    _bitrate = path == ucPathDirect ? 4000000 : 1500000;

    final size = await capture.start(
      width: maxWidth > 0 ? maxWidth : 1280,
      height: (maxWidth > 0 ? maxWidth : 1280) * 2, // bound by width; host keeps aspect
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
    state = HostState.sharing;
    _controlOn = false;
    _history.clear();
    _historyOrder.clear();

    // Open the media datagram channel toward the viewer with the fallback the
    // current relay mode allows.
    session.node?.openDatagrams(session.topicId, dev, session.mediaFallback);

    session.sendControl(dev, {
      't': 'scr.started',
      'request': request,
      'session': _session,
      'codec': 'h264',
      'width': _width,
      'height': _height,
      'fps': _fps,
      'monitors': 1,
      'control': false,
      'cursorEmbedded': true,
    });

    // An initial wantControl request is handled once sharing is up.
    if (msg['wantControl'] == true) {
      unawaited(_setControl(dev, request, true));
    }

    _auSub = capture.accessUnits().listen(_onAccessUnit);
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
  // trust/permission/consent gate as screen viewing (7.5).
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

  static const int _payloadMax = 1084; // 1100-byte datagram minus 16-byte header

  void _onAccessUnit(CaptureUnit u) {
    final dev = _viewer;
    if (dev == null || state != HostState.sharing) return;
    final seq = _seq & 0xFFFFFFFF;
    _seq++;
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
      _send(dev, dg);
    }
    _remember(seq, datagrams);
  }

  Uint8List _packet(int seq, int index, int count, bool keyframe,
      bool retransmit, int ts, Uint8List payload) {
    final dg = Uint8List(16 + payload.length);
    final bd = ByteData.sublistView(dg);
    dg[0] = 1; // screen video
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

  // Minimal rate control (7.2): ease the bitrate down on sustained loss and
  // back up when clean, within [300 kbit, start].
  int _cleanReports = 0;
  void _onReport(Map<String, Object?> msg) {
    final received = _intf(msg, 'received');
    final lost = _intf(msg, 'lost');
    final total = received + lost;
    if (total == 0) return;
    final lossPct = lost * 100 / total;
    if (lossPct > 5) {
      _cleanReports = 0;
      final next = max(300000, (_bitrate * 0.8).round());
      if (next != _bitrate) {
        _bitrate = next;
        capture.setBitrate(_bitrate);
      }
    } else {
      _cleanReports++;
      if (_cleanReports >= 3) {
        _cleanReports = 0;
        final cap = session.node?.datagramPath(session.topicId, _viewer ?? '') ==
                ucPathDirect
            ? 6000000
            : 2500000;
        final next = min(cap, (_bitrate * 1.05).round() + 50000);
        if (next != _bitrate) {
          _bitrate = next;
          capture.setBitrate(_bitrate);
        }
      }
    }
  }

  /// Stops sharing (user pressed Stop, or the app is leaving the screen).
  Future<void> stop() async {
    final dev = _viewer;
    if (dev != null && _session != 0) {
      session.sendControl(dev, {'t': 'scr.stop', 'session': _session});
    }
    await _teardownAsync();
  }

  void _teardown() {
    unawaited(_teardownAsync());
  }

  Future<void> _teardownAsync() async {
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
    await _teardownAsync();
    await _changed.close();
  }
}
