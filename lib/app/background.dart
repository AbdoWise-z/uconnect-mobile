// Keeps the app running while backgrounded so the uConnect session stays up.
//
// The session's networking lives on a native thread inside libuconnect_c.so;
// it keeps the encrypted link and its keepalives alive on its own as long as
// the process is not killed or frozen. What ends a backgrounded process is
// the OS, so on Android we hold a foreground service for as long as the user
// wants to be connected (UconnectService.kt). The Dart event pump pauses
// while backgrounded and its queued events drain on resume; the link itself
// does not drop.
//
// Two things still end it, and the app can only tell the user about them:
// Android 12+ refuses to start a foreground service from the background (so
// the service is kept through reconnects rather than stopped and restarted),
// and the device may be set to put the app to sleep (battery optimisation;
// the user can exempt the app from Settings › Topic & connection).
//
// iOS gives a backgrounded app only a short grace period unless it holds a
// specific background mode, so there the session survives being backgrounded
// briefly and is re-established on resume. This class no-ops off Android.

import 'dart:io';

import 'package:flutter/services.dart';

class BackgroundKeepAlive {
  static const _channel = MethodChannel('uconnect/service');
  bool _running = false;

  /// Starts (or updates) the foreground service with a status line. Safe to
  /// call repeatedly; only acts on Android. False when the system refused
  /// it (started from the background, or the day's allowance used up).
  Future<bool> start(String text) async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('start', {'text': text}) ?? true;
      _running = ok;
      return ok;
    } on PlatformException {
      // The service could not start (e.g. notifications blocked on old OEM
      // builds); the app still works in the foreground.
      return false;
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // ignore
    }
    _running = false;
  }

  /// True when Android will not put the app to sleep in the background;
  /// null where the question does not apply.
  Future<bool?> isExemptFromBatteryOptimizations() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>('batteryOptimizations');
    } on PlatformException {
      return null;
    }
  }

  /// Shows the system prompt that exempts the app.
  Future<void> requestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } on PlatformException {
      // nothing to open
    }
  }
}
