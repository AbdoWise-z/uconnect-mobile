// Glues the pieces together for the UI: loads the store and identity, owns
// the Session and the storage services, and exposes everything as a
// ChangeNotifier the widgets listen to. The counterpart of the desktop app's
// AppController.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/identity.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import '../core/storage/storage_client.dart';
import '../core/storage/storage_offerer.dart';
import '../core/wire.dart';
import '../uconnect/uconnect.dart';
import 'store.dart';

class AppState extends ChangeNotifier {
  AppState(this.dataDir)
      : store = AppStore('$dataDir${Platform.pathSeparator}state.json');

  final String dataDir;
  final AppStore store;
  Identity? identity;

  final session = Session();
  late final storageClient = StorageClient(session);
  late final storageOfferer = StorageOfferer(session);

  bool loaded = false;
  String startError = '';
  final _subs = <StreamSubscription<void>>[];

  String get downloadsDir => '$dataDir${Platform.pathSeparator}downloads';
  String get sharedDir => '$dataDir${Platform.pathSeparator}shared';

  Future<void> init() async {
    await store.load();
    identity =
        await Identity.loadOrCreate('$dataDir${Platform.pathSeparator}identity');
    session.identity = identity;
    if (store.deviceName.isEmpty) {
      store.deviceName = Platform.isAndroid
          ? 'Android device'
          : Platform.isIOS
              ? 'iPhone'
              : 'uConnect device';
    }
    // A default share so the device has something to offer out of the box.
    await Directory(sharedDir).create(recursive: true);
    await Directory(downloadsDir).create(recursive: true);
    if (store.shares.isEmpty) {
      store.shares = [SharedFolder('Shared', sharedDir)];
    }
    _applyLocalConfig();
    _subs.add(session.changed.listen((_) => notifyListeners()));
    _subs.add(storageClient.transfersChanged.listen((_) => notifyListeners()));
    _subs.add(storageOfferer.activityChanged.listen((_) => notifyListeners()));
    loaded = true;
    notifyListeners();
    if (store.server.isNotEmpty && store.topicUri.isNotEmpty) {
      unawaited(connect());
    }
  }

  void _applyLocalConfig() {
    storageOfferer.offered = store.offerStorage;
    storageOfferer.shares = store.shares;
    session.setLocalHello(Hello(
      name: store.deviceName,
      os: Platform.isAndroid
          ? 'android'
          : Platform.isIOS
              ? 'ios'
              : Platform.operatingSystem,
      services: [if (store.offerStorage) Services.storage],
    ));
    session.setAccessPolicy(AccessPolicy(
      defaults: normalizePermissions(store.defaultPermissions),
      trusted: {
        for (final t in store.trusted.values)
          t.keyHex: normalizePermissions(t.permissions)
      },
    ));
  }

  bool get connected => session.status == SessionStatus.online;

  Future<void> connect() async {
    startError = '';
    final creds = TopicCreds.parse(store.topicUri);
    if (creds == null) {
      startError = 'The invite link is not a valid uconn:// URI.';
      notifyListeners();
      return;
    }
    try {
      await session.start(SessionOptions(
        server: store.server,
        creds: creds,
        forceRelay: store.forceRelay,
      ));
      _applyLocalConfig();
    } on Object catch (e) {
      startError = e.toString();
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await session.stop();
    notifyListeners();
  }

  /// Creates a new keyed topic locally and stores its invite link.
  Future<String?> createTopic() async {
    final creds = TopicCreds.generate();
    store.topicUri = creds.toUri();
    await store.save();
    notifyListeners();
    return store.topicUri;
  }

  Future<void> saveSettings({
    String? server,
    String? topicUri,
    String? deviceName,
    bool? offerStorage,
    bool? forceRelay,
  }) async {
    if (server != null) store.server = server.trim();
    if (topicUri != null) store.topicUri = topicUri.trim();
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      store.deviceName = deviceName.trim();
    }
    if (offerStorage != null) store.offerStorage = offerStorage;
    if (forceRelay != null) store.forceRelay = forceRelay;
    await store.save();
    _applyLocalConfig();
    notifyListeners();
  }

  // --- trust and permissions -------------------------------------------------

  Future<void> trustDevice(String keyHex, String name) async {
    store.trusted.putIfAbsent(
        keyHex,
        () => TrustedDevice(
            keyHex, name, normalizePermissions(store.defaultPermissions)));
    await store.save();
    _applyLocalConfig();
  }

  Future<void> untrustDevice(String keyHex) async {
    store.trusted.remove(keyHex);
    await store.save();
    _applyLocalConfig();
  }

  Future<void> setTrustedPermissions(String keyHex, Set<String> perms) async {
    final t = store.trusted[keyHex];
    if (t == null) return;
    t.permissions = perms;
    await store.save();
    _applyLocalConfig();
  }

  Future<void> setDefaultPermissions(Set<String> perms) async {
    store.defaultPermissions =
        perms..removeWhere(isTrustedOnlyPermission);
    await store.save();
    _applyLocalConfig();
  }

  // --- shares ------------------------------------------------------------------

  Future<void> setShares(List<SharedFolder> shares) async {
    store.shares = shares;
    await store.save();
    _applyLocalConfig();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    storageOfferer.dispose();
    unawaited(session.dispose());
    super.dispose();
  }
}
