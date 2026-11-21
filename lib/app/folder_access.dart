// Folders outside the app's own, on iOS: a folder picked in the Files picker
// (iCloud Drive, "On My iPhone", another app's folder) can be read and written
// only while iOS has been asked for it again in this run of the app. The
// native side (ios/Runner/SyncPlatform.swift) keeps a bookmark for each picked
// folder and reopens them all at launch; this is its Dart face.
//
// Android has no counterpart: there a picked folder is a plain path, usable
// once "All files access" is granted (storage_access.dart).

import 'dart:io';

import 'package:flutter/services.dart';

class FolderAccess {
  static const _channel = MethodChannel('uconnect/storage');

  /// Whether picked folders go through here.
  static bool get supported => Platform.isIOS;

  /// Shows the system's folder picker. The folder's path, usable from now on
  /// and after a restart; null when the user backs out.
  static Future<String?> pick() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('pickFolder');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Reopens every folder picked in earlier runs; call before anything reads
  /// a saved folder. Maps the path each was saved under to its path now,
  /// which differs when its provider moved it, and is empty while it cannot
  /// be reached.
  static Future<Map<String, String>> restore() async {
    if (!supported) return const {};
    try {
      final map =
          await _channel.invokeMapMethod<String, String>('restoreFolders');
      return map ?? const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// Gives a folder up: its access is closed and it is not reopened again.
  static Future<void> release(String path) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('releaseFolder', {'path': path});
    } on PlatformException {
      // nothing held
    } on MissingPluginException {
      // not on this platform
    }
  }

  /// Keeps a folder the app can already reach as a picked one is kept. The
  /// picker does this itself; tests use it in the picker's place.
  static Future<String?> adopt(String path) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('adoptFolder', {'path': path});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// How saved folder paths are brought up to date at launch on iOS: a picked
/// folder goes where its bookmark says it is now, and is otherwise left
/// alone; any other path inside an app container moves to this install's
/// container (container_paths.dart). A picked folder can itself lie inside
/// another app's container, which must not be mistaken for an old one of
/// ours.
String Function(String path) savedPathMapper(
    Map<String, String> picked, String Function(String path) rebase) {
  return (path) {
    final now = picked[path];
    if (now == null) return rebase(path);
    return now.isEmpty ? path : now;
  };
}
