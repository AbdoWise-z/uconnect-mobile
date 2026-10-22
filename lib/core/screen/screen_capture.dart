// Dart side of the native screen capture + encoder (ScreenCapturer.kt). Shows
// Android's capture-consent dialog, starts encoding, and streams the encoded
// H.264 access units. Android only; elsewhere capture is unsupported.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class CaptureUnit {
  CaptureUnit(this.bytes, this.keyframe, this.ptsUs);
  final Uint8List bytes;
  final bool keyframe;
  final int ptsUs;
}

/// A source of encoded H.264 access units the host fragments and sends: the
/// screen (CaptureController) or the camera (CameraCaptureController). The host
/// (screen_host.dart) drives any of these the same way.
abstract class VideoSource {
  bool get supported;
  Stream<CaptureUnit> accessUnits();

  /// Obtains permission to capture (the OS screen-capture dialog, or the camera
  /// runtime permission); true when granted.
  Future<bool> requestConsent();
  Future<Size> start(
      {required int width,
      required int height,
      required int fps,
      required int bitrate});
  Future<void> requestKeyframe();
  Future<void> setBitrate(int bitrate);
  Future<void> stop();
}

class CaptureController implements VideoSource {
  static const _channel = MethodChannel('uconnect/capture');
  static const _events = EventChannel('uconnect/capture/au');

  bool get supported => Platform.isAndroid;

  Stream<CaptureUnit> accessUnits() {
    return _events.receiveBroadcastStream().map((e) {
      final m = e as Map;
      return CaptureUnit(
        m['bytes'] as Uint8List,
        m['keyframe'] as bool? ?? false,
        (m['ptsUs'] as num?)?.toInt() ?? 0,
      );
    });
  }

  /// Shows the OS screen-capture consent dialog; true if the user allows it.
  Future<bool> requestConsent() async {
    if (!supported) return false;
    final r = await _channel.invokeMapMethod<String, Object?>('requestConsent');
    return r?['granted'] == true;
  }

  /// Starts the encoder; returns the actual encoded size (even dimensions,
  /// the phone's aspect ratio within the requested bounds).
  Future<Size> start(
      {required int width,
      required int height,
      required int fps,
      required int bitrate}) async {
    final r = await _channel.invokeMapMethod<String, Object?>('start', {
      'width': width,
      'height': height,
      'fps': fps,
      'bitrate': bitrate,
    });
    return Size(((r?['width'] as num?) ?? 0).toDouble(),
        ((r?['height'] as num?) ?? 0).toDouble());
  }

  Future<void> requestKeyframe() =>
      _channel.invokeMethod<void>('requestKeyframe');

  Future<void> setBitrate(int bitrate) =>
      _channel.invokeMethod<void>('setBitrate', {'bitrate': bitrate});

  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
