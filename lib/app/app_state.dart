// Glues the pieces together for the UI: loads the store and identity, owns
// the Session and the storage services, and exposes everything as a
// ChangeNotifier the widgets listen to. The counterpart of the desktop app's
// AppController.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/identity.dart';
import '../core/permissions.dart';
import '../core/screen/remote_input.dart';
import '../core/screen/screen_capture.dart';
import '../core/screen/screen_host.dart';
import '../core/session.dart';
import '../core/storage/storage_client.dart';
import '../core/storage/storage_offerer.dart';
import '../core/wire.dart';
import '../uconnect/uconnect.dart';
import '../ui/theme.dart';
import 'background.dart';
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
  final capture = CaptureController();
  final input = RemoteInput();
  late final ScreenHost screenHost;

  /// Set by the app shell so the screen-consent prompt has a context.
  final navigatorKey = GlobalKey<NavigatorState>();

  bool loaded = false;
  String startError = '';
  bool _controlAvailable = false;
  bool get controlAvailable => _controlAvailable;
  final _subs = <StreamSubscription<void>>[];
  final _background = BackgroundKeepAlive();

  String get downloadsDir => '$dataDir${Platform.pathSeparator}downloads';
  String get sharedDir => '$dataDir${Platform.pathSeparator}shared';

  Future<void> init() async {
    await store.load();
    screenHost =
        ScreenHost(session, capture, input, askConsent: _askScreenConsent);
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
    screenHost.offered = store.offerScreen;
    _controlAvailable = await input.available();
    _subs.add(session.changed.listen((_) {
      _syncBackgroundService();
      notifyListeners();
    }));
    _subs.add(screenHost.changed.listen((_) => notifyListeners()));
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
    final screenOn = store.offerScreen && capture.supported;
    final controlOn = store.offerControl && _controlAvailable;
    screenHost.offered = screenOn;
    screenHost.offerControl = controlOn;
    session.setLocalHello(Hello(
      name: store.deviceName,
      os: Platform.isAndroid
          ? 'android'
          : Platform.isIOS
              ? 'ios'
              : Platform.operatingSystem,
      services: [
        if (store.offerStorage) Services.storage,
        if (screenOn) Services.screen,
        if (controlOn) Services.control,
      ],
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

  String _lastBgText = '';

  // A session that is up, connecting or retrying holds the foreground service
  // so the OS keeps the process alive in the background; offline/error drop it.
  void _syncBackgroundService() {
    final status = session.status;
    final text = switch (status) {
      SessionStatus.online => () {
          final n = session.peers.values.where((p) => p.stateCode == 3).length;
          return n == 0
              ? 'Connected · waiting for your devices'
              : 'Connected to $n device${n == 1 ? '' : 's'}';
        }(),
      SessionStatus.connecting ||
      SessionStatus.reconnecting =>
        'Connecting to your devices…',
      SessionStatus.offline || SessionStatus.error => '',
    };
    if (text.isEmpty) {
      _lastBgText = '';
      _background.stop();
    } else if (text != _lastBgText) {
      _lastBgText = text;
      _background.start(text);
    }
  }

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
    bool? offerScreen,
    bool? offerControl,
    bool? forceRelay,
    int? screenMaxWidth,
    int? screenMaxFps,
  }) async {
    if (server != null) store.server = server.trim();
    if (topicUri != null) store.topicUri = topicUri.trim();
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      store.deviceName = deviceName.trim();
    }
    if (offerStorage != null) store.offerStorage = offerStorage;
    if (offerScreen != null) store.offerScreen = offerScreen;
    if (offerControl != null) store.offerControl = offerControl;
    if (forceRelay != null) store.forceRelay = forceRelay;
    if (screenMaxWidth != null) store.screenMaxWidth = screenMaxWidth;
    if (screenMaxFps != null) store.screenMaxFps = screenMaxFps;
    await store.save();
    _applyLocalConfig();
    notifyListeners();
  }

  /// Re-checks whether the accessibility service is on (the user may have just
  /// toggled it in Settings) and re-applies the hello so control is offered.
  Future<void> refreshControlAvailability() async {
    final was = _controlAvailable;
    _controlAvailable = await input.available();
    if (_controlAvailable != was) {
      _applyLocalConfig();
      notifyListeners();
    }
  }

  // Asks the user to allow a peer to watch this screen, or (control) to also
  // control it. Unless the peer holds the matching ".direct" grant.
  Future<bool> _askScreenConsent(String dev, String name,
      {bool control = false}) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(control ? 'Let it control your device?' : 'Share your screen?'),
        content: Text(
          control
              ? '"$name" is asking to control this device — tap, swipe, scroll '
                  'and type — while it watches your screen.'
              : '"$name" is asking to watch this device\'s screen. While you '
                  'share, it sees everything on your screen.',
          style: const TextStyle(color: UcColors.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(control ? 'Allow control' : 'Share'),
          ),
        ],
      ),
    );
    return ok ?? false;
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

  /// Tears the live connection down without disposing the notifier; called
  /// when the OS is detaching the engine, so the native node does not linger.
  void shutdown() {
    unawaited(_background.stop());
    unawaited(screenHost.stop());
    unawaited(session.stop());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_background.stop());
    unawaited(screenHost.dispose());
    storageOfferer.dispose();
    unawaited(session.dispose());
    super.dispose();
  }
}
