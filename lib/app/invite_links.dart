// Topic invite links (uconn://<topic>#<key>) that open the app: a QR code of
// another device's invite scanned with the camera, or a tapped link. The
// platform side hands them over on the "uconnect/link" channel -- MainActivity
// on Android, InviteLinks in AppDelegate.swift on iOS.

import 'package:flutter/services.dart';

class InviteLinks {
  InviteLinks(this.onLink);

  final void Function(String link) onLink;

  static const _channel = MethodChannel('uconnect/link');
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Starts listening, and delivers the link the app was opened with, if any.
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        _deliver(call.arguments as String);
      }
      return null;
    });
    try {
      final initial = await _channel.invokeMethod<String>('initial');
      if (initial != null) _deliver(initial);
    } on MissingPluginException {
      // a platform without the link channel (desktop, tests)
    } on PlatformException {
      // nothing to deliver
    }
  }

  // At startup the same link can come by both paths; act on it once.
  void _deliver(String link) {
    final now = DateTime.now();
    if (link == _last && now.difference(_lastAt).inSeconds < 3) return;
    _last = link;
    _lastAt = now;
    onLink(link);
  }
}
