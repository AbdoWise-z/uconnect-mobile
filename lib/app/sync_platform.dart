// What folder sync asks the platform for beyond files (SyncPlatform.kt on
// Android): whether the phone is on an unmetered network and charging, with
// changes as they happen; plain notifications for sync problems; and the
// free space of the disk a folder is on. Off Android everything is "yes" and
// "unknown", so sync is never held back where nothing can tell.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// The conditions "sync only on Wi-Fi" and "only while charging" look at.
class PowerConditions {
  PowerConditions(this.onChange);

  final void Function() onChange;
  static const _channel = MethodChannel('uconnect/power');
  static const _events = EventChannel('uconnect/power/events');
  StreamSubscription<Object?>? _sub;

  bool wifi = true; // the active network is unmetered
  bool charging = true;
  bool known = false;

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      _apply(await _channel.invokeMethod<Map>('state'));
    } on PlatformException {
      // stays unknown
    } on MissingPluginException {
      return;
    }
    _sub = _events.receiveBroadcastStream().listen((v) {
      if (v is Map) _apply(v);
    }, onError: (Object _) {});
  }

  void _apply(Map? v) {
    if (v == null) return;
    final w = v['wifi'] == true, c = v['charging'] == true;
    if (known && w == wifi && c == charging) return;
    wifi = w;
    charging = c;
    known = true;
    onChange();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}

/// A notification of its own for something sync needs the user for.
class SyncNotifier {
  static const _channel = MethodChannel('uconnect/notify');

  /// Shown at most once per `key` until [reset].
  final _shown = <String>{};
  int _nextId = 2000;

  Future<void> show(String key, String title, String text) async {
    if (!Platform.isAndroid || !_shown.add(key)) return;
    try {
      await _channel.invokeMethod<void>('show', {
        'id': _nextId++,
        'title': title,
        'text': text,
      });
    } on PlatformException {
      // not allowed: the app's own pages still show it
    } on MissingPluginException {
      // not on this platform
    }
  }

  void reset(String key) => _shown.remove(key);
}

/// Bytes free on the disk holding `path`; -1 when unknown.
Future<int> freeSpaceOf(String path) async {
  if (!Platform.isAndroid) return -1;
  try {
    return await const MethodChannel('uconnect/storage')
            .invokeMethod<int>('freeSpace', {'path': path}) ??
        -1;
  } on PlatformException {
    return -1;
  } on MissingPluginException {
    return -1;
  }
}
