// Watches a peer's shared screen: requests the session, shows the decoded
// video in a Flutter texture, and (when the host grants control) forwards
// pointer, scroll and keyboard events to the host as in.* messages. The host
// applies them on its own machine; the phone only sends them.
//
// The video can be pinch-zoomed and panned, the phone can be rotated (or
// forced full-screen landscape), and a keyboard bar sends typed text and the
// common editing/navigation keys while controlling.

import 'dart:async';
import 'dart:ui' as ui;

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

/// What a viewer can ask the other device for: a resolution, a frame rate
/// and a bitrate (it scales and paces down to them, and caps each by its own
/// limits), and how long a playback buffer to keep. The phone remembers the
/// choice (AppStore.screenMaxWidth/Fps, viewBitrate, viewBufferMs).
class ViewQuality {
  static const widths = <int>[3840, 2560, 1920, 1280, 854];
  static const frameRates = <int>[15, 24, 30, 60, 90, 120];
  static const bitrates = <int>[0, 2000000, 4000000, 8000000, 16000000, 32000000, 50000000];
  static const buffers = <int>[-1, 0, 50, 100, 150, 250, 500]; // -1: automatic

  static String widthLabel(int width) => switch (width) {
        3840 => 'Original',
        2560 => '1440p',
        1920 => '1080p',
        1280 => '720p',
        854 => '480p',
        _ => '$width px',
      };
  static String bitrateLabel(int bitrate) =>
      bitrate <= 0 ? 'Automatic' : '${bitrate ~/ 1000000} Mbit/s';
  static String bufferLabel(int ms) => ms < 0 ? 'Automatic' : ms == 0 ? 'None' : '$ms ms';
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
  // A decoder start is under way; _decoderWanted counts the restarts asked
  // for (a quality change, a retry), so one asked for meanwhile is not lost.
  bool _startingDecoder = false;
  int _decoderWanted = 0;
  final _focusNode = FocusNode();
  final _keyboard = TextEditingController();
  final _transform = TransformationController();
  int _buttons = 0;
  int _rotation = 0; // camera preview, quarter turns
  bool _keyboardOn = false;
  bool _fullscreen = false;
  String _typed = '';
  // The statistics overlay, and the decoder's figures for it (polled).
  bool _showStats = false;
  Timer? _statsTimer;
  Map<String, Object?> _render = const {};

  @override
  void initState() {
    super.initState();
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
      if (_viewer.active && _textureId == null && !_startingDecoder && _decoder.supported) {
        _startingDecoder = true;
        final wanted = _decoderWanted;
        final id = await _decoder.start(_viewer, bufferMs: _bufferMs());
        _startingDecoder = false;
        if (mounted && id != null && wanted == _decoderWanted) setState(() => _textureId = id);
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
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!_showStats || !mounted) return;
      final render = await _decoder.stats();
      if (mounted) setState(() => _render = render);
    });
    // The playout buffer in use: the automatic one follows the network.
    _bufferTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _textureId == null) return;
      final ms = _bufferMs();
      _viewer.playoutMs = ms;
      if (widget.state.store.viewBufferMs < 0 && ms != _appliedBufferMs) {
        _appliedBufferMs = ms;
        _decoder.setBuffer(ms);
      }
    });
    _startView();
  }

  Timer? _bufferTimer;
  int _appliedBufferMs = -1;

  // The playout buffer to use: the setting, or the viewer's automatic one.
  int _bufferMs() {
    final chosen = widget.state.store.viewBufferMs;
    return chosen < 0 ? _viewer.autoPlayoutMs : chosen;
  }

  // Requests the stream at the quality the user has selected. Used on open and
  // on "Try again" so a retry keeps the chosen quality instead of reverting.
  void _startView({bool? wantControl}) {
    final store = widget.state.store;
    _viewer.request(widget.devId,
        wantControl: wantControl ?? widget.startControl,
        maxWidth: store.screenMaxWidth,
        maxFps: store.screenMaxFps,
        maxBitrate: store.viewBitrate);
  }

  // Re-requests the stream with a changed quality (remembered for next time).
  // The host re-encodes, so rebuild the decoder for a clean start, and keep
  // control if we had it.
  Future<void> _ask({int? width, int? fps, int? bitrate, int? bufferMs}) async {
    final store = widget.state.store;
    if ((width ?? store.screenMaxWidth) == store.screenMaxWidth &&
        (fps ?? store.screenMaxFps) == store.screenMaxFps &&
        (bitrate ?? store.viewBitrate) == store.viewBitrate &&
        (bufferMs ?? store.viewBufferMs) == store.viewBufferMs) {
      return;
    }
    final wasControlling = _canControl && _viewer.controlOn;
    await widget.state.saveSettings(
        screenMaxWidth: width,
        screenMaxFps: fps,
        viewBitrate: bitrate,
        viewBufferMs: bufferMs);
    if (!mounted) return;
    setState(() {
      _textureId = null;
      _decoderWanted++;
    });
    _startView(wantControl: wasControlling || widget.startControl);
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
    _statsTimer?.cancel();
    _bufferTimer?.cancel();
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
      if (widget.camera && _viewer.active)
        IconButton(
          tooltip: 'Rotate',
          icon: const Icon(Icons.screen_rotation),
          onPressed: () => setState(() => _rotation = (_rotation + 1) % 4),
        ),
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

  // Opens the quality sheet: what to ask the host for, the playback buffer,
  // and the statistics overlay.
  Widget _qualityMenu({Color? color}) {
    return IconButton(
      tooltip: 'Quality',
      icon: Icon(Icons.high_quality_outlined, color: color),
      onPressed: _openQualitySheet,
    );
  }

  void _openQualitySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: UcColors.panel,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final store = widget.state.store;
          Widget row<T>(String title, List<T> values, T current, String Function(T) label,
                  void Function(T) pick) =>
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title.toUpperCase(),
                        style: TextStyle(
                            fontSize: 11.5,
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.w600,
                            color: UcColors.textSecondary)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      for (final v in values)
                        ChoiceChip(
                          label: Text(label(v)),
                          selected: v == current,
                          onSelected: (_) async {
                            pick(v);
                            setSheet(() {});
                          },
                        ),
                    ]),
                  ],
                ),
              );
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row<int>('Resolution', ViewQuality.widths, store.screenMaxWidth,
                      ViewQuality.widthLabel, (v) => _ask(width: v)),
                  row<int>('Frame rate', ViewQuality.frameRates, store.screenMaxFps,
                      (v) => '$v fps', (v) => _ask(fps: v)),
                  row<int>('Bitrate', ViewQuality.bitrates, store.viewBitrate,
                      ViewQuality.bitrateLabel, (v) => _ask(bitrate: v)),
                  row<int>('Playback buffer', ViewQuality.buffers, store.viewBufferMs,
                      ViewQuality.bufferLabel, (v) => _ask(bufferMs: v)),
                  SwitchListTile(
                    title: const Text('Statistics'),
                    subtitle: const Text('How the stream keeps up, on both devices'),
                    value: _showStats,
                    onChanged: (on) {
                      setState(() => _showStats = on);
                      setSheet(() {});
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Everything about how the stream keeps up: what this phone receives and
  // shows, its playback buffer, and how the host is doing.
  Widget _statsOverlay() {
    String n(Object? v, [int digits = 0]) =>
        v is num ? v.toStringAsFixed(digits) : '–';
    final store = widget.state.store;
    final host = _viewer.hostStats;
    final lines = <String>[
      'Asked ${ViewQuality.widthLabel(store.screenMaxWidth)}, ${store.screenMaxFps} fps, '
          '${ViewQuality.bitrateLabel(store.viewBitrate)}',
      'Received ${n(_viewer.unitsPerSecond)} fps · ${n(_viewer.kbps / 1000, 1)} Mbit/s · '
          'loss ${n(_viewer.lossPct, 1)}% · jitter ${n(_viewer.jitterMs, 1)} ms',
      'Shown ${n(_render['rendered'])} fps · late ${n(_render['late'])} · '
          'buffer ${n(_render['bufferMs'] ?? _bufferMs())} ms${store.viewBufferMs < 0 ? ' (automatic)' : ''} · '
          'recovered ${_viewer.lastSecond.recovered} · repeats ${_viewer.lastSecond.repaired} · given up ${_viewer.lastSecond.givenUp}',
      if (host['rttMs'] is num)
        'Path: round trip ${n(host['rttMs'])} ms · loss ${n(host['lossPct'], 1)}% · '
            '${(host['fec'] as num? ?? 0) > 0 ? 'repair 1 per ${n(host['fec'])}' : 'no repair'} · '
            'lag ${n(host['lagMs'])} ms · ${host['estimator'] ?? ''}',
      if (host.isNotEmpty)
        'Host: ${n(host['fps'])} fps'
            '${host['encodeMs'] is num ? ', encode ${n(host['encodeMs'], 1)} ms' : ''}'
            '${host['queue'] is num ? ' · queue ${n(host['queue'], 1)}' : ''}'
            '${host['dropped'] is num ? ' · dropped ${n(host['dropped'], 1)}/s' : ''}',
      if (host.isNotEmpty)
        'Host target: ${n(host['targetFps'])} fps, ${n((host['targetKbps'] as num? ?? 0) / 1000, 1)} Mbit/s, '
            '${n(host['width'])} px · ${host['pipeline'] ?? ''}',
    ];
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(lines.join('\n'),
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontFamily: 'monospace', height: 1.35)),
      ),
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
          if (widget.camera)
            IconButton(
              tooltip: 'Rotate',
              icon: const Icon(Icons.screen_rotation, color: Colors.white),
              onPressed: () => setState(() => _rotation = (_rotation + 1) % 4),
            ),
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
                  setState(() {
                    _textureId = null;
                    _decoderWanted++;
                  });
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

    Widget content = controlling
        ? _controlSurface(id, aspect)
        : AspectRatio(
            aspectRatio: aspect,
            child: Stack(fit: StackFit.expand, children: [
              Texture(textureId: id),
              if (!widget.camera) _CursorOverlay(viewer: _viewer),
            ]),
          );
    // Quarter-turn the camera preview (sideways phone, etc.).
    if (widget.camera && _rotation != 0) {
      content = RotatedBox(quarterTurns: _rotation, child: content);
    }

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
        if (_showStats) Positioned(left: 8, top: 8, child: _statsOverlay()),
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
                side: BorderSide(color: UcColors.inputBorder),
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
            Expanded(
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
          child: Stack(fit: StackFit.expand, children: [
            Texture(textureId: textureId),
            _CursorOverlay(viewer: _viewer),
          ]),
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

// Draws the host's mouse cursor over the video. The desktop sends the cursor
// separately (shape as a PNG, position as a datagram) rather than blending it
// into the frame — see ScreenViewer.cursorImages / cursorMoves — so without
// this the pointer would be invisible on the phone. It fills the video box and
// scales the cursor's native-pixel position into it. Skipped when the host
// embeds the cursor in the frame itself (cursorEmbedded).
class _CursorOverlay extends StatefulWidget {
  const _CursorOverlay({required this.viewer});
  final ScreenViewer viewer;

  @override
  State<_CursorOverlay> createState() => _CursorOverlayState();
}

class _CursorOverlayState extends State<_CursorOverlay> {
  ui.Image? _image;
  int _hotspotX = 0;
  int _hotspotY = 0;
  double _x = 0;
  double _y = 0;
  bool _visible = false;
  StreamSubscription<CursorImage>? _imageSub;
  StreamSubscription<CursorMove>? _moveSub;

  @override
  void initState() {
    super.initState();
    // Seed from whatever the viewer has already received, since these streams
    // don't buffer and the shape may have arrived before we subscribed.
    final move = widget.viewer.lastCursorMove;
    if (move != null) {
      _x = move.x.toDouble();
      _y = move.y.toDouble();
      _visible = move.visible;
    }
    final image = widget.viewer.lastCursorImage;
    if (image != null) {
      _hotspotX = image.hotspotX;
      _hotspotY = image.hotspotY;
      decodeImageFromList(image.png).then((decoded) {
        if (!mounted) {
          decoded.dispose();
          return;
        }
        setState(() => _image = decoded);
      });
    }
    _moveSub = widget.viewer.cursorMoves.listen((m) {
      if (!mounted) return;
      setState(() {
        _x = m.x.toDouble();
        _y = m.y.toDouble();
        _visible = m.visible;
      });
    });
    _imageSub = widget.viewer.cursorImages.listen((c) async {
      final decoded = await decodeImageFromList(c.png);
      if (!mounted) {
        decoded.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = decoded;
        _hotspotX = c.hotspotX;
        _hotspotY = c.hotspotY;
      });
    });
  }

  @override
  void dispose() {
    _imageSub?.cancel();
    _moveSub?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (widget.viewer.cursorEmbedded || !_visible || image == null) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CursorPainter(
          image: image,
          x: _x,
          y: _y,
          hotspotX: _hotspotX.toDouble(),
          hotspotY: _hotspotY.toDouble(),
          spaceWidth: widget.viewer.cursorSpaceWidth.toDouble(),
          spaceHeight: widget.viewer.cursorSpaceHeight.toDouble(),
        ),
      ),
    );
  }
}

class _CursorPainter extends CustomPainter {
  _CursorPainter({
    required this.image,
    required this.x,
    required this.y,
    required this.hotspotX,
    required this.hotspotY,
    required this.spaceWidth,
    required this.spaceHeight,
  });

  final ui.Image image;
  final double x;
  final double y;
  final double hotspotX;
  final double hotspotY;
  final double spaceWidth;
  final double spaceHeight;

  @override
  void paint(Canvas canvas, Size size) {
    if (spaceWidth <= 0 || spaceHeight <= 0) return;
    // The cursor's position and size are in the source's native pixels; scale
    // them by how large the video is drawn here.
    final scaleX = size.width / spaceWidth;
    final scaleY = size.height / spaceHeight;
    final dst = Rect.fromLTWH(
      (x - hotspotX) * scaleX,
      (y - hotspotY) * scaleY,
      image.width * scaleX,
      image.height * scaleY,
    );
    final src = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_CursorPainter old) =>
      old.image != image ||
      old.x != x ||
      old.y != y ||
      old.hotspotX != hotspotX ||
      old.hotspotY != hotspotY ||
      old.spaceWidth != spaceWidth ||
      old.spaceHeight != spaceHeight;
}
