// Dart side of input injection (UconnectAccessibilityService.kt). Forwards a
// controlling peer's pointer, scroll, key and text events to the accessibility
// service, which performs them on this device. Normalized coordinates (0..1)
// are scaled to real screen pixels natively. Android only.

import 'dart:io';

import 'package:flutter/services.dart';

class RemoteInput {
  static const _channel = MethodChannel('uconnect/input');

  bool get platformSupported => Platform.isAndroid;

  /// Whether the accessibility service is currently enabled and running.
  Future<bool> available() async {
    if (!platformSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Android's accessibility settings so the user can turn the service on.
  Future<void> openSettings() async {
    if (!platformSupported) return;
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on PlatformException {
      // ignore
    }
  }

  void pointer(double nx, double ny, bool pressed) {
    if (!platformSupported) return;
    _channel.invokeMethod<void>('pointer', {'x': nx, 'y': ny, 'pressed': pressed});
  }

  void scroll(double nx, double ny, int dx, int dy) {
    if (!platformSupported) return;
    _channel.invokeMethod<void>('scroll', {'x': nx, 'y': ny, 'dx': dx, 'dy': dy});
  }

  void key(int usage) {
    if (!platformSupported) return;
    _channel.invokeMethod<void>('key', {'usage': usage});
  }

  void text(String value) {
    if (!platformSupported || value.isEmpty) return;
    _channel.invokeMethod<void>('text', {'text': value});
  }

  void release() {
    if (!platformSupported) return;
    _channel.invokeMethod<void>('release');
  }
}
