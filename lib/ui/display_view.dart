// This device as another's extended display (protocol 7.6): the host's
// virtual monitor, full screen. Opened by AppState when a request has been
// accepted, and closed when the session ends from either side.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/keep_awake.dart';
import '../core/screen/screen_decoder.dart';
import 'screen_view.dart' show CursorOverlay;
import 'theme.dart';

class DisplayPage extends StatefulWidget {
  const DisplayPage({required this.state, super.key});

  final AppState state;

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage> {
  final _decoder = ScreenDecoder();
  StreamSubscription<void>? _sink;
  StreamSubscription<Size>? _size;
  int? _textureId;
  bool _starting = false;
  bool _barShown = false;
  Timer? _barTimer;
  bool _closed = false;
  late final String _hostName;

  @override
  void initState() {
    super.initState();
    final sink = widget.state.displaySink;
    _hostName =
        widget.state.session.peers[sink.host]?.displayName ?? 'another device';
    // A monitor: the whole screen, lying down, and never asleep.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(keepScreenOn(true));
    _sink = sink.changed.listen((_) => _follow());
    _size = _decoder.sizeChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _follow();
  }

  // Starts the decoder once pictures can come, and leaves when the session is
  // over.
  void _follow() {
    final sink = widget.state.displaySink;
    if (!sink.showing) {
      _close();
      return;
    }
    if (sink.viewer.active && _textureId == null && !_starting) {
      _starting = true;
      // Each picture as soon as it is decoded: a monitor should not lag.
      _decoder.start(sink.viewer, bufferMs: 0).then((id) {
        _starting = false;
        if (mounted) setState(() => _textureId = id);
      });
    }
    if (mounted) setState(() {});
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).maybePop();
  }

  void _stop() {
    widget.state.displaySink.stop(); // _follow closes the page
  }

  void _toggleBar() {
    _barTimer?.cancel();
    setState(() => _barShown = !_barShown);
    if (_barShown) {
      _barTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _barShown = false);
      });
    }
  }

  @override
  void dispose() {
    _barTimer?.cancel();
    _sink?.cancel();
    _size?.cancel();
    _decoder.dispose();
    // Leaving by any road (back, the stop button, the app closing) ends it.
    if (widget.state.displaySink.showing) widget.state.displaySink.stop();
    unawaited(keepScreenOn(false));
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewer = widget.state.displaySink.viewer;
    final id = _textureId;
    final w = _decoder.size.width > 0 ? _decoder.size.width : viewer.width;
    final h = _decoder.size.height > 0 ? _decoder.size.height : viewer.height;
    final aspect = (w > 0 && h > 0) ? w / h : 16 / 9;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleBar,
        child: Stack(fit: StackFit.expand, children: [
          if (id != null)
            Center(
              child: AspectRatio(
                aspectRatio: aspect,
                child: Stack(fit: StackFit.expand, children: [
                  Texture(textureId: id),
                  CursorOverlay(viewer: viewer),
                ]),
              ),
            )
          else
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  viewer.statusDetail.isNotEmpty
                      ? viewer.statusDetail
                      : 'Waiting for $_hostName to start its display…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: UcColors.textSecondary),
                ),
              ]),
            ),
          // A tap shows who this is a display for, and the way out.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 160),
            top: _barShown ? 0 : -72,
            left: 0,
            right: 0,
            child: Material(
              color: UcColors.panel.withValues(alpha: 0.92),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    Icon(Icons.desktop_windows_outlined,
                        size: 20, color: UcColors.textSecondary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Extended display for $_hostName'
                        '${w > 0 ? ' · ${w.toInt()}×${h.toInt()}' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: UcColors.text),
                      ),
                    ),
                    FilledButton(onPressed: _stop, child: const Text('Stop')),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
