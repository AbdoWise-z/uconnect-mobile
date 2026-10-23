// Dart side of the native camera capture + encoder (CameraCapturer.kt): opens
// a device camera through Camera2, encodes it to H.264 and streams the access
// units, the same shape as screen_capture.dart so the host can drive either.
// Android only; elsewhere camera capture is unsupported.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'screen_capture.dart' show CaptureUnit, VideoSource;

class CameraInfo {
  CameraInfo(this.id, this.facing);
  final String id;
  final String facing; // 'front' | 'back' | 'external'
}

String _cameraLabel(String facing) => switch (facing) {
      'front' => 'Front camera',
      'back' => 'Back camera',
      _ => 'External camera',
    };

class CameraCaptureController implements VideoSource {
  static const _channel = MethodChannel('uconnect/camera');
  static const _events = EventChannel('uconnect/camera/au');

  /// Which camera to open on the next start: a Camera2 id, or null for the
  /// first back-facing one.
  String? cameraId;

  /// Every camera on the device (loaded once by AppState), and the ids the user
  /// chose to offer (empty = all). [offered] is the resulting list a viewer
  /// sees and picks from.
  List<CameraInfo> allCameras = const [];
  Set<String> offeredIds = const {};

  List<CameraInfo> get offered => offeredIds.isEmpty
      ? allCameras
      : [for (final c in allCameras) if (offeredIds.contains(c.id)) c];

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<List<String>> sources() async =>
      [for (final c in offered) _cameraLabel(c.facing)];

  @override
  void selectSource(int index) {
    final list = offered;
    if (index >= 0 && index < list.length) cameraId = list[index].id;
  }

  @override
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

  /// The cameras this device has, for a picker.
  Future<List<CameraInfo>> cameras() async {
    if (!supported) return const [];
    final r = await _channel.invokeListMethod<Object?>('cameras');
    return [
      for (final c in r ?? const [])
        if (c is Map)
          CameraInfo(c['id'] as String? ?? '', c['facing'] as String? ?? '')
    ];
  }

  /// Requests the camera runtime permission; true when granted.
  @override
  Future<bool> requestConsent() async {
    if (!supported) return false;
    final r = await _channel.invokeMapMethod<String, Object?>('requestPermission');
    return r?['granted'] == true;
  }

  /// Starts the camera and encoder; returns the actual encoded size. The camera
  /// caps the resolution/fps to what it supports.
  @override
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
      if (cameraId != null) 'cameraId': cameraId,
    });
    return Size(((r?['width'] as num?) ?? 0).toDouble(),
        ((r?['height'] as num?) ?? 0).toDouble());
  }

  @override
  Future<void> requestKeyframe() =>
      _channel.invokeMethod<void>('requestKeyframe');

  @override
  Future<void> setBitrate(int bitrate) =>
      _channel.invokeMethod<void>('setBitrate', {'bitrate': bitrate});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  // A camera keeps the size and rate it was started with.
  @override
  Future<Size> resize({required int width, required int fps}) async => Size.zero;
}
