// Watches a peer's shared screen: requests the session, shows the decoded
// video in a Flutter texture, and (when the host grants control) forwards
// pointer, scroll and keyboard events to the host as in.* messages. The host
// applies them on its own machine; the phone only sends them.
//
// The video can be pinch-zoomed and panned, the phone can be rotated (or
// forced full-screen landscape), and a keyboard bar sends typed text and the
// common editing/navigation keys while controlling.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../core/screen/screen_decoder.dart';
import '../core/screen/screen_viewer.dart';
import 'theme.dart';

// USB HID keyboard-page usages for the keys the keyboard bar can send.
class _Hid {
  static const enter = 0x28;
  static const escape = 0x29;
  static const backspace = 0x2A;
  static const tab = 0x2B;
  static const right = 0x4F;
  static const left = 0x50;
  static const down = 0x51;
  static const up = 0x52;
}

/// A resolution/frame-rate the viewer can ask the host to encode at. The host
/// scales and paces down to this, so a lower one keeps playback smooth when the
/// phone's decoder cannot keep up with a full desktop. The user picks one from
/// the screen view; the choice is remembered (AppStore.screenMaxWidth/Fps).
class ScreenQuality {
  const ScreenQuality(this.label, this.maxWidth, this.maxFps);
  final String label;
  final int maxWidth;
  final int maxFps;

  static const presets = <ScreenQuality>[
    ScreenQuality('Full', 1920, 60),
    ScreenQuality('High', 1600, 30),
    ScreenQuality('Medium', 1280, 30),
    ScreenQuality('Low', 960, 30),
  ];

  bool matches(int width, int fps) => width == maxWidth && fps == maxFps;

  /// The preset for a stored choice, falling back to the closest by width.
  static ScreenQuality forStore(int width, int fps) {
    for (final q in presets) {
      if (q.matches(width, fps)) return q;
    }
    var best = presets.first;
    for (final q in presets) {
      if ((q.maxWidth - width).abs() < (best.maxWidth - width).abs()) best = q;
    }
    return best;
  }
}

class ScreenView extends StatefulWidget {
  const ScreenView({
    required this.state,
    required this.devId,
    required this.devName,
    this.startControl = false,
    this.camera = false,
    super.key,
  });

  final AppState state;
  final String devId;
  final String devName;

  /// Open straight into controlling (take control as soon as it is available),
  /// rather than view-only.
  final bool startControl;

  /// Watch the peer's camera (cam.* protocol) instead of its screen. A camera
  /// stream has no control or keyboard channel.
  final bool camera;

  @override
  State<ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<ScreenView> {
  late final ScreenViewer _viewer;
  late final ScreenDecoder _decoder;
  int? _textureId;
  final _focusNode = FocusNode();
  final _keyboard = TextEditingController();
  final _transform = TransformationController();
  int _buttons = 0;
  bool _keyboardOn = false;
  bool _fullscreen = false;
  String _typed = '';
  late ScreenQuality _quality;

  @override
  void initState() {
    super.initState();
    _quality = ScreenQuality.forStore(
        widget.state.store.screenMaxWidth, widget.state.store.screenMaxFps);
    // Let the view rotate freely while open.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _viewer = ScreenViewer(widget.state.session,
        prefix: widget.camera ? 'cam' : 'scr');
    _decoder = ScreenDecoder();
    _viewer.changed.listen((_) async {
      if (!mounted) return;
      if (_viewer.active && _textureId == null && _decoder.supported) {
        final id = await _decoder.start(_viewer);
        if (mounted) setState(() => _textureId = id);
      }
      // Auto-take control when opened as a control session.
      if (widget.startControl &&
          _viewer.active &&
          _canControl &&
          !_viewer.controlOn) {
        _viewer.requestControl(true);
      }
      if (mounted) setState(() {});
    });
    _decoder.sizeChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _startView();
  }

  // Requests the stream at the quality the user has selected. Used on open and
  // on "Try again" so a retry keeps the chosen quality instead of reverting.
  void _startView() {
    _viewer.request(widget.devId,
        wantControl: widget.startControl,
        maxWidth: _quality.maxWidth,
        maxFps: _quality.maxFps);
  }

  // Re-requests the stream at a different resolution/frame rate. The host
  // re-encodes at the new size, so rebuild the decoder for a clean start and
  // keep control if we had it.
  void _changeQuality(ScreenQuality q) {
    if (q.matches(_quality.maxWidth, _quality.maxFps)) return;
    final wasControlling = _canControl && _viewer.controlOn;
    setState(() {
      _quality = q;
      _textureId = null;
    });
    widget.state
        .saveSettings(screenMaxWidth: q.maxWidth, screenMaxFps: q.maxFps);
    _viewer.request(widget.devId,
        wantControl: wasControlling || widget.startControl,
        maxWidth: q.maxWidth,
        maxFps: q.maxFps);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _viewer.releaseInput();
    _viewer.dispose();
    _decoder.dispose();
    _focusNode.dispose();
    _keyboard.dispose();
    _transform.dispose();
    super.dispose();
  }

  bool get _canControl {
    if (widget.camera) return false; // a camera stream has no control channel
    final granted = widget.state.session.peers[widget.devId]?.grantedToMe ?? [];
    return granted.contains('control.input');
  }

  void _toggleKeyboard() {
    setState(() => _keyboardOn = !_keyboardOn);
    // The bar's field autofocuses when shown; just drop focus when hiding.
    if (!_keyboardOn) _focusNode.unfocus();
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen && _viewer.state == ViewerState.active) {
      // No chrome in full-screen: a floating exit/keyboard control instead.
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(child: _body()),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: _floatingControls(),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text('${widget.devName} — ${widget.camera ? 'camera' : 'screen'}',
            style: const TextStyle(fontSize: 15)),
        actions: _appBarActions(),
      ),
      body: Column(
        children: [
          Expanded(child: _body()),
          if (_keyboardOn && _viewer.controlOn) _keyboardBar(),
        ],
      ),
    );
  }

  List<Widget> _appBarActions() {
    return [
      if (widget.camera && _viewer.active && _viewer.cameras.length > 1)
        _cameraMenu(),
      if (_viewer.active) _qualityMenu(),
      if (_viewer.active)
        IconButton(
          tooltip: 'Full screen',
          icon: const Icon(Icons.fullscreen),
          onPressed: _toggleFullscreen,
        ),
      if (_viewer.active && _canControl)
        IconButton(
          tooltip: _viewer.controlOn ? 'Stop controlling' : 'Take control',
          icon: Icon(_viewer.controlOn ? Icons.mouse : Icons.mouse_outlined),
          color: _viewer.controlOn ? UcColors.accent : null,
          onPressed: () => _viewer.requestControl(!_viewer.controlOn),
        ),
      if (_viewer.active && _viewer.controlOn)
        IconButton(
          tooltip: 'Keyboard',
          icon: Icon(_keyboardOn ? Icons.keyboard_hide : Icons.keyboard),
          color: _keyboardOn ? UcColors.accent : null,
          onPressed: _toggleKeyboard,
        ),
    ];
  }

  // Lets the viewer switch which of the host's cameras is being shown
  // (cam.monitor). Only shown when the host offers more than one.
  Widget _cameraMenu({Color? color}) {
    return PopupMenuButton<int>(
      tooltip: 'Camera',
      icon: Icon(Icons.cameraswitch_outlined, color: color),
      onSelected: _viewer.selectMonitor,
      itemBuilder: (_) => [
        for (var i = 0; i < _viewer.cameras.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                Icon(i == _viewer.monitor ? Icons.check : null,
                    size: 18, color: UcColors.accent),
                const SizedBox(width: 8),
                Text(_viewer.cameras[i]),
              ],
            ),
          ),
      ],
    );
  }

  // Lets the user pick the stream quality. A lower one keeps motion smooth when
  // the decoder cannot keep up; the pick is remembered across sessions.
  Widget _qualityMenu({Color? color}) {
    return PopupMenuButton<ScreenQuality>(
      tooltip: 'Quality (${_quality.label})',
      icon: Icon(Icons.high_quality_outlined, color: color),
      onSelected: _changeQuality,
      itemBuilder: (_) => [
        for (final q in ScreenQuality.presets)
          PopupMenuItem<ScreenQuality>(
            value: q,
            child: Row(
              children: [
                Icon(
                  q.matches(_quality.maxWidth, _quality.maxFps)
                      ? Icons.check
                      : null,
                  size: 18,
                  color: UcColors.accent,
                ),
                const SizedBox(width: 8),
                Text('${q.label}  ·  ${q.maxWidth}×${q.maxFps}fps'),
              ],
            ),
          ),
      ],
    );
  }

  Widget _floatingControls() {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.camera && _viewer.cameras.length > 1)
            _cameraMenu(color: Colors.white),
          _qualityMenu(color: Colors.white),
          if (_canControl)
            IconButton(
              tooltip: _viewer.controlOn ? 'Stop controlling' : 'Take control',
              icon: Icon(_viewer.controlOn ? Icons.mouse : Icons.mouse_outlined,
                  color: _viewer.controlOn ? UcColors.accent : Colors.white),
              onPressed: () => _viewer.requestControl(!_viewer.controlOn),
            ),
          IconButton(
            tooltip: 'Exit full screen',
            icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
            onPressed: _toggleFullscreen,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_viewer.state) {
      case ViewerState.requesting:
        return _status('Asking ${widget.devName} to share its '
            '${widget.camera ? 'camera' : 'screen'}…');
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
                  _startView();
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
    final controlling = _canControl && _viewer.controlOn;

    final content = controlling
        ? _controlSurface(id, aspect)
        : AspectRatio(aspectRatio: aspect, child: Texture(textureId: id));

    // Pinch to zoom and pan. While controlling, a single finger drives the
    // pointer (panEnabled false) and two fingers still zoom/pan.
    final zoomable = InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 6,
      panEnabled: !controlling,
      scaleEnabled: true,
      clipBehavior: Clip.hardEdge,
      child: content,
    );

    return Stack(
      children: [
        Positioned.fill(child: Container(color: Colors.black)),
        Center(child: zoomable),
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
        if (_viewer.active && _canControl && !_viewer.controlOn && !_fullscreen)
          Positioned(left: 12, right: 12, bottom: 12, child: _hintBar()),
      ],
    );
  }

  // Sends what changed in the text field as in.text (inserted characters) and
  // backspace keys (deletions), so typing on the soft keyboard reaches the host.
  void _onTyped(String v) {
    var common = 0;
    final max = v.length < _typed.length ? v.length : _typed.length;
    while (common < max && v[common] == _typed[common]) {
      common++;
    }
    final deletes = _typed.length - common;
    for (var i = 0; i < deletes; i++) {
      _viewer.sendKey(_Hid.backspace, true);
    }
    final added = v.substring(common);
    if (added.isNotEmpty) _viewer.sendText(added);
    _typed = v;
    // Keep the field from growing without bound.
    if (v.length > 240) {
      _keyboard.clear();
      _typed = '';
    }
  }

  // A single compact row so it fits even in landscape with the soft keyboard
  // up (a taller, stacked bar overflowed the shrunken body there). The special
  // keys scroll horizontally on the left; a narrow capture field on the right
  // feeds typed characters to the host via _onTyped.
  Widget _keyboardBar() {
    Widget key(String label, int usage) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: SizedBox(
            width: 44,
            height: 38,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(44, 38),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: UcColors.text,
                side: const BorderSide(color: UcColors.inputBorder),
              ),
              onPressed: () => _viewer.sendKey(usage, true),
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ),
        );
    return Material(
      color: UcColors.panel,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      key('Esc', _Hid.escape),
                      key('Tab', _Hid.tab),
                      key('⌫', _Hid.backspace),
                      key('↵', _Hid.enter),
                      key('←', _Hid.left),
                      key('→', _Hid.right),
                      key('↑', _Hid.up),
                      key('↓', _Hid.down),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: _keyboard,
                  focusNode: _focusNode,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofocus: true,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    hintText: 'Type…',
                  ),
                  onChanged: _onTyped,
                ),
              ),
            ],
          ),
        ),
      ),
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

  // The Listener sits exactly on the letterboxed video (inside the
  // AspectRatio), so a touch maps straight to a normalized position regardless
  // of the zoom/pan transform applied by the InteractiveViewer around it.
  //
  // Only a single finger drives the pointer; a second finger means a
  // pinch-zoom/pan, so control is released and the gesture is left to the
  // InteractiveViewer -- otherwise both fingers would fling the cursor around.
  final _pointers = <int>{};
  int? _controlPointer;

  Widget _controlSurface(int textureId, double aspect) {
    return AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(builder: (context, constraints) {
        final box = constraints.biggest;
        return Listener(
          onPointerDown: (e) {
            _pointers.add(e.pointer);
            if (_pointers.length == 1) {
              _controlPointer = e.pointer;
              _buttons = MouseButton.left;
              _emit(e.localPosition, box);
            } else if (_controlPointer != null) {
              // A pinch began: release the held press and stop controlling.
              _buttons = 0;
              _emit(e.localPosition, box);
              _controlPointer = null;
            }
          },
          onPointerMove: (e) {
            if (e.pointer == _controlPointer && _pointers.length == 1) {
              _emit(e.localPosition, box);
            }
          },
          onPointerUp: (e) => _endPointer(e.pointer, e.localPosition, box),
          onPointerCancel: (e) => _endPointer(e.pointer, e.localPosition, box),
          child: Texture(textureId: textureId),
        );
      }),
    );
  }

  void _endPointer(int pointer, Offset pos, Size box) {
    _pointers.remove(pointer);
    if (pointer == _controlPointer) {
      _buttons = 0;
      _emit(pos, box);
      _controlPointer = null;
    }
  }

  void _emit(Offset pos, Size box) {
    final nx = (pos.dx / box.width).clamp(0.0, 1.0);
    final ny = (pos.dy / box.height).clamp(0.0, 1.0);
    _viewer.sendPointer(nx, ny, _buttons);
  }
}
