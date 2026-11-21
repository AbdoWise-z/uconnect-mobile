// Being another device's extended display (protocol 7.6): a host asks this
// device to act as one of its monitors, this device answers with the screen
// it will show it on, and the host creates a virtual monitor of that mode and
// streams it.
//
// The handshake runs the other way round from screen viewing: the sending
// side asks (dsp.request), and this side accepts (dsp.accept). From there it
// is a screen session under dsp.* names, with video on datagram kind 4 and the
// cursor on kind 5, which a ScreenViewer with the 'dsp' prefix receives.
//
// A host may ask only if it has proven its identity and holds display.show
// here. Without display.direct the user is asked each time.

import 'dart:async';

import '../permissions.dart';
import '../session.dart';
import 'screen_viewer.dart';

/// The screen a host's picture will be shown on, in pixels, as sent in
/// dsp.accept: the host sizes its virtual monitor from it.
class DisplayScreen {
  const DisplayScreen(
      {required this.width,
      required this.height,
      required this.fps,
      required this.dpi});
  final int width, height, fps;
  final double dpi;
}

/// Asks the user to let `name` use this device as an extended display.
typedef DisplayConsent = Future<bool> Function(String dev, String name);

class DisplaySink {
  DisplaySink(this.session,
      {required this.askConsent,
      required this.screen,
      this.maxWidth = 1920,
      this.maxFps = 60}) {
    // Before the viewer's own handler, which takes every dsp.* message.
    session.addControlHandler(_onControl);
    viewer = ScreenViewer(session, prefix: 'dsp');
    session.addPeerStateHandler((dev, state) {
      if (dev == _host && (state == 4 || state == 5)) _clear();
    });
    viewer.changed.listen((_) {
      // The session ended (either side's stop, an error, the 15 s wait for
      // dsp.started): this device is free for another request.
      if (_accepted &&
          (viewer.state == ViewerState.stopped ||
              viewer.state == ViewerState.failed)) {
        _clear(keepReason: true);
      } else {
        _notify();
      }
    });
  }

  final Session session;
  final DisplayConsent askConsent;

  /// The screen to answer with, read when a request is accepted.
  final DisplayScreen Function() screen;

  /// What this device decodes: the host keeps its mode within these.
  final int maxWidth, maxFps;

  /// Whether this device offers to be an extended display; mirrors the hello.
  bool offered = false;

  /// Receives the session once a request is accepted.
  late final ScreenViewer viewer;

  String? _host;
  int _request = 0;
  bool _accepted = false;

  final _changed = StreamController<void>.broadcast();
  Stream<void> get changed => _changed.stream;

  /// The device this one is, or is about to be, a display for.
  String get host => _host ?? '';

  /// A request was accepted and its session is starting or running.
  bool get showing => _accepted;

  /// Why the last session ended, when it did not end by a plain stop.
  String get lastError => viewer.state == ViewerState.failed ? viewer.error : '';

  void _notify() {
    if (!_changed.isClosed) _changed.add(null);
  }

  void _clear({bool keepReason = false}) {
    _host = null;
    _request = 0;
    _accepted = false;
    _notify();
  }

  void _err(String dev, int request, String code) => session
      .sendControl(dev, {'t': 'dsp.err', 'request': request, 'code': code});

  bool _mayShow(String dev) {
    final peer = session.peers[dev];
    return offered &&
        peer != null &&
        peer.identityState == 'verified' &&
        session.permissionsFor(dev).contains(Perm.displayShow);
  }

  bool _onControl(String dev, Map<String, Object?> msg) {
    final t = msg['t'];
    if (t == 'dsp.request') {
      unawaited(_onRequest(dev, msg));
      return true;
    }
    // Before it is accepted, the host's stop names the request and there is
    // no viewer session yet to take it.
    if (t == 'dsp.stop' &&
        dev == _host &&
        !_accepted &&
        msg['request'] is num &&
        (msg['request'] as num).toInt() == _request) {
      _clear();
      return true;
    }
    return false; // the media session's messages: the viewer's
  }

  Future<void> _onRequest(String dev, Map<String, Object?> msg) async {
    final request = msg['request'] is num ? (msg['request'] as num).toInt() : 0;
    if (request == 0) return;
    if (!_mayShow(dev)) return _err(dev, request, 'forbidden');
    final codecs = msg['codecs'];
    if (codecs is! List || !codecs.contains('h264')) {
      return _err(dev, request, 'codec');
    }
    // One extended display at a time.
    if (_host != null) return _err(dev, request, 'busy');
    _host = dev;
    _request = request;
    _accepted = false;
    _notify();

    if (!session.permissionsFor(dev).contains(Perm.displayDirect)) {
      session.sendControl(dev, {'t': 'dsp.wait', 'request': request});
      final name = session.peers[dev]?.displayName ?? 'A device';
      // The prompt denies by itself after 30 s (7.6).
      final ok = await askConsent(dev, name)
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
      // The host may have cancelled, left, or lost the permission meanwhile.
      if (_host != dev || _request != request || _accepted) return;
      if (!ok || !_mayShow(dev)) {
        _clear();
        return _err(dev, request, 'denied');
      }
    }
    _accept(dev, request);
  }

  void _accept(String dev, int request) {
    final s = screen();
    _accepted = true;
    // The viewer waits for dsp.started under this request, 15 s at most.
    viewer.expect(dev, request);
    session.sendControl(dev, {
      't': 'dsp.accept',
      'request': request,
      'screen': {
        'width': s.width,
        'height': s.height,
        'fps': s.fps,
        'dpi': s.dpi,
      },
      'maxWidth': maxWidth,
      'maxFps': maxFps,
    });
    _notify();
  }

  /// Ends the session, or declines a request still being asked about.
  void stop() {
    final dev = _host;
    if (dev == null) return;
    if (_accepted) {
      viewer.stop(); // tells the host, by session or by request
    } else {
      _err(dev, _request, 'denied');
    }
    _clear();
  }

  Future<void> dispose() async {
    stop();
    session.removeControlHandler(_onControl);
    await viewer.dispose();
    await _changed.close();
  }
}
