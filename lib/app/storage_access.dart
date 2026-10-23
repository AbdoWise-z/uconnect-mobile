// Storage access for folder sync into a folder the user picks anywhere on
// shared storage. Android 11+ needs "All files access" for that (the system
// folder picker gives content:// trees, which cannot be renamed into or have
// their times set, as sync needs); earlier Android, the storage permission.
// The default sync location (the app's own folder) needs neither, and iOS
// keeps synced folders in the app's Documents.

import 'dart:io';

import 'package:flutter/services.dart';

class StorageAccess {
  static const _channel = MethodChannel('uconnect/storage');

  /// Whether folders anywhere on shared storage can be synced.
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system page (or prompt) to grant it; the user comes back to
  /// the app afterwards, so check again then.
  static Future<void> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } on PlatformException {
      // nothing to open
    } on MissingPluginException {
      // not on this platform
    }
  }
}
