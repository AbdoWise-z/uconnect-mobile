// Dart side of the native H.264 decoder (ScreenDecoder.kt). Creates a Flutter
// texture, feeds it the access units from a ScreenViewer, and reports the
// decoded size. Android only for now; elsewhere `textureId` stays null and the
// view shows the "not supported on this platform" state.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'screen_viewer.dart';

class ScreenDecoder {
  static const _channel = MethodChannel('uconnect/screen');

  int? textureId;
  Size size = Size.zero;
  final _sizeChanged = StreamController<Size>.broadcast();
  final _errors = StreamController<String>.broadcast();
  Stream<Size> get sizeChanged => _sizeChanged.stream;
  Stream<String> get errors => _errors.stream;

  StreamSubscription<VideoAccessUnit>? _sub;
  bool _disposed = false;

  bool get supported => Platform.isAndroid;

  ScreenDecoder() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'size':
          final a = call.arguments as Map;
          size = Size((a['width'] as num).toDouble(),
              (a['height'] as num).toDouble());
          if (!_sizeChanged.isClosed) _sizeChanged.add(size);
        case 'error':
          if (!_errors.isClosed) _errors.add(call.arguments as String? ?? '');
      }
      return null;
    });
  }

  /// Creates the texture and starts decoding [viewer]'s access units into it.
  /// Safe to call again (e.g. after a quality change): the previous unit
  /// subscription is cancelled first so units are never fed to the freshly
  /// created decoder twice, which would corrupt it and ghost the picture.
  Future<int?> start(ScreenViewer viewer) async {
    if (!supported) return null;
    await _sub?.cancel();
    _sub = null;
    final created =
        await _channel.invokeMapMethod<String, Object?>('create');
    textureId = created?['textureId'] as int?;
    _sub = viewer.units.listen((u) async {
      if (_disposed) return;
      final started = DateTime.now();
      try {
        await _channel.invokeMethod<void>('decode', {
          'bytes': u.bytes,
          'keyframe': u.keyframe,
          'ptsUs': u.captureMs * 1000,
        });
      } on PlatformException {
        // one bad unit should not tear the stream down
      }
      viewer.reportDecodeMs(DateTime.now().difference(started).inMilliseconds);
    });
    return textureId;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    if (supported) {
      try {
        await _channel.invokeMethod<void>('dispose');
      } on PlatformException {
        // ignore
      }
    }
    await _sizeChanged.close();
    await _errors.close();
  }
}
