// Keeps the app running while backgrounded so the uConnect session stays up.
//
// The session's networking lives on a native thread inside libuconnect_c.so;
// it keeps the encrypted link and its keepalives alive on its own as long as
// the process is not killed. What ends a backgrounded process is the OS, so on
// Android we hold a foreground service for as long as a session is connected
// (UconnectService.kt). The Dart event pump pauses while backgrounded and its
// queued events drain on resume; the link itself does not drop.
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
  /// call repeatedly; only acts on Android.
  Future<void> start(String text) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
      _running = true;
    } on PlatformException {
      // The service could not start (e.g. notifications blocked on old OEM
      // builds); the app still works in the foreground.
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
}
