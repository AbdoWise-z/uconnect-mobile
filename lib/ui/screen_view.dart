// Watches a peer's shared screen: requests the session, shows the decoded
// video in a Flutter texture, and (when the host grants control) forwards
// pointer, scroll and keyboard events to the host as in.* messages. The host
// applies them on its own machine; the phone only sends them.

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/screen/screen_decoder.dart';
import '../core/screen/screen_viewer.dart';
import 'theme.dart';

class ScreenView extends StatefulWidget {
  const ScreenView({
    required this.state,
    required this.devId,
    required this.devName,
    super.key,
  });

  final AppState state;
  final String devId;
  final String devName;

  @override
  State<ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<ScreenView> {
  late final ScreenViewer _viewer;
  late final ScreenDecoder _decoder;
  int? _textureId;
  final _focusNode = FocusNode();
  final _keyboard = TextEditingController();
  int _buttons = 0;

  @override
  void initState() {
    super.initState();
    _viewer = ScreenViewer(widget.state.session);
    _decoder = ScreenDecoder();
    _viewer.changed.listen((_) async {
      if (!mounted) return;
      if (_viewer.active && _textureId == null && _decoder.supported) {
        final id = await _decoder.start(_viewer);
        if (mounted) setState(() => _textureId = id);
      }
      if (mounted) setState(() {});
    });
    _decoder.sizeChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _viewer.request(widget.devId, wantControl: false);
  }

  @override
  void dispose() {
    _viewer.releaseInput();
    _viewer.dispose();
    _decoder.dispose();
    _focusNode.dispose();
    _keyboard.dispose();
    super.dispose();
  }

  bool get _canControl {
    final granted = widget.state.session.peers[widget.devId]?.grantedToMe ?? [];
    return granted.contains('control.input');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('${widget.devName} — screen',
            style: const TextStyle(fontSize: 15)),
        actions: [
          if (_viewer.active && _viewer.controlOffered)
            IconButton(
              tooltip: _viewer.controlOn ? 'Stop controlling' : 'Take control',
              icon: Icon(_viewer.controlOn
                  ? Icons.mouse
                  : Icons.mouse_outlined),
              color: _viewer.controlOn ? UcColors.accent : null,
              onPressed: () => _viewer.requestControl(!_viewer.controlOn),
            ),
          if (_viewer.active && _viewer.controlOn)
            IconButton(
              tooltip: 'Keyboard',
              icon: const Icon(Icons.keyboard),
              onPressed: () => _focusNode.requestFocus(),
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    switch (_viewer.state) {
      case ViewerState.requesting:
        return _status('Asking ${widget.devName} to share its screen…');
      case ViewerState.waiting:
        return _status('Waiting for ${widget.devName} to allow it…');
      case ViewerState.failed:
        return _status(_viewer.error, error: true, retry: true);
      case ViewerState.stopped:
        return _status('The screen session ended.', retry: true);
      case ViewerState.idle:
        return _status('…');
      case ViewerState.active:
        return _video();
    }
  }

  Widget _status(String text, {bool error = false, bool retry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!error && !retry)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: CircularProgressIndicator(),
              ),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: error ? UcColors.error : UcColors.textSecondary)),
            if (retry) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() => _textureId = null);
                  _viewer.request(widget.devId);
                },
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _video() {
    final id = _textureId;
    if (!_decoder.supported) {
      return _status('Watching a screen is not supported on this platform yet.',
          error: true);
    }
    if (id == null) {
      return _status('Starting the decoder…');
    }
    final w = _decoder.size.width > 0 ? _decoder.size.width : _viewer.width;
    final h = _decoder.size.height > 0 ? _decoder.size.height : _viewer.height;
    final aspect = (w > 0 && h > 0) ? w / h : 16 / 9;

    final video = AspectRatio(
      aspectRatio: aspect,
      child: Texture(textureId: id),
    );

    // Hidden text field that drives in.text / in.key while control is on.
    final keyboardSink = SizedBox(
      width: 0,
      height: 0,
      child: Offstage(
        offstage: true,
        child: TextField(
          controller: _keyboard,
          focusNode: _focusNode,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.text,
          onChanged: (v) {
            if (v.isNotEmpty) {
              _viewer.sendText(v);
              _keyboard.clear();
            }
          },
          onSubmitted: (_) => _viewer.sendKey(0x28, true), // HID Enter
        ),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: Container(color: Colors.black)),
        Center(
          child: _canControl && _viewer.controlOn
              ? _controlSurface(video, aspect)
              : video,
        ),
        keyboardSink,
        if (_viewer.statusDetail.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(8),
              child: Text(_viewer.statusDetail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ),
        if (_viewer.active && _viewer.controlOffered && !_viewer.controlOn)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _hintBar(),
          ),
      ],
    );
  }

  Widget _hintBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: UcColors.panel.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text('View only. Take control to use the mouse and keyboard.',
                  style:
                      TextStyle(color: UcColors.textSecondary, fontSize: 12)),
            ),
            TextButton(
              onPressed: () => _viewer.requestControl(true),
              child: const Text('Take control'),
            ),
          ],
        ),
      );

  // Maps touches on the video to normalized pointer coordinates and buttons.
  Widget _controlSurface(Widget video, double aspect) {
    return LayoutBuilder(builder: (context, constraints) {
      return Listener(
        onPointerDown: (e) {
          _buttons = MouseButton.left;
          _emit(e.localPosition, constraints.biggest, aspect);
        },
        onPointerMove: (e) => _emit(e.localPosition, constraints.biggest, aspect),
        onPointerUp: (e) {
          _buttons = 0;
          _emit(e.localPosition, constraints.biggest, aspect);
        },
        child: video,
      );
    });
  }

  void _emit(Offset pos, Size box, double aspect) {
    // The video is letterboxed inside the box; map to the video rect.
    double vw = box.width, vh = box.width / aspect;
    if (vh > box.height) {
      vh = box.height;
      vw = box.height * aspect;
    }
    final left = (box.width - vw) / 2;
    final top = (box.height - vh) / 2;
    final nx = ((pos.dx - left) / vw).clamp(0.0, 1.0);
    final ny = ((pos.dy - top) / vh).clamp(0.0, 1.0);
    _viewer.sendPointer(nx, ny, _buttons);
  }
}
