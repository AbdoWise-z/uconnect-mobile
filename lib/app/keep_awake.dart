// Keeps the screen from dimming and locking while this device is being a
// display (MainActivity.kt sets FLAG_KEEP_SCREEN_ON; SyncPlatform.swift the
// idle timer). Does nothing where the platform side is missing.

import 'package:flutter/services.dart';

const _channel = MethodChannel('uconnect/window');

Future<void> keepScreenOn(bool on) async {
  try {
    await _channel.invokeMethod<void>('keepScreenOn', {'on': on});
  } on PlatformException {
    // the screen follows its usual timeout
  } on MissingPluginException {
    // not on this platform
  }
}
