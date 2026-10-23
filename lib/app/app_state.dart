// Glues the pieces together for the UI: loads the store and identity, owns
// the Session and the storage services, and exposes everything as a
// ChangeNotifier the widgets listen to. The counterpart of the desktop app's
// AppController.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/identity.dart';
import '../core/network_rules.dart';
import '../core/permissions.dart';
import '../core/screen/remote_input.dart';
import '../core/screen/screen_capture.dart';
import '../core/screen/camera_capture.dart';
import '../core/screen/screen_host.dart';
import '../core/session.dart';
import '../core/storage/storage_client.dart';
import '../core/storage/storage_offerer.dart';
import '../core/wire.dart';
import '../uconnect/uconnect.dart';
import '../ui/theme.dart';
import 'background.dart';
import 'invite_links.dart';
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
  final cameraCapture = CameraCaptureController();
  final input = RemoteInput();
  late final ScreenHost screenHost;
  late final ScreenHost cameraHost;

  /// Set by the app shell so the screen-consent prompt has a context.
  final navigatorKey = GlobalKey<NavigatorState>();

  bool loaded = false;
  String startError = '';
  bool _controlAvailable = false;
  bool get controlAvailable => _controlAvailable;

  /// The device's cameras, for the camera-offer settings.
  List<CameraInfo> get cameras => cameraCapture.allCameras;
  final _subs = <StreamSubscription<void>>[];
  final _background = BackgroundKeepAlive();

  String get downloadsDir => '$dataDir${Platform.pathSeparator}downloads';
  String get sharedDir => '$dataDir${Platform.pathSeparator}shared';

  Future<void> init() async {
    await store.load();
    screenHost =
        ScreenHost(session, capture, input, askConsent: _askScreenConsent);
    // The camera reuses the host, as cam.* with video kind 3 and no control or
    // "direct" grant (a camera always asks for consent).
    cameraHost = ScreenHost(session, cameraCapture, input,
        askConsent: _askScreenConsent,
        prefix: 'cam',
        videoKind: 3,
        viewPerm: Perm.cameraView,
        directPerm: Perm.cameraDirect);
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
    // Enumerate the device's cameras once, for the offer settings and picker.
    if (cameraCapture.supported) {
      try {
        cameraCapture.allCameras = await cameraCapture.cameras();
      } on Object {
        cameraCapture.allCameras = const [];
      }
    }
    _applyLocalConfig();
    screenHost.offered = store.offerScreen;
    cameraHost.offered = store.offerCamera && cameraCapture.supported;
    _controlAvailable = await input.available();
    _subs.add(session.changed.listen((_) {
      _syncBackgroundService();
      notifyListeners();
    }));
    _subs.add(screenHost.changed.listen((_) => notifyListeners()));
    _subs.add(cameraHost.changed.listen((_) => notifyListeners()));
    _subs.add(storageClient.transfersChanged.listen((_) => notifyListeners()));
    _subs.add(storageOfferer.activityChanged.listen((_) => notifyListeners()));
    loaded = true;
    notifyListeners();
    if (store.server.isNotEmpty && store.topicUri.isNotEmpty) {
      unawaited(connect());
    }
    unawaited(_inviteLinks.start());
    unawaited(_refreshLocalAddresses());
    _addressTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => unawaited(_refreshLocalAddresses()));
  }

  // --- invite links (QR codes / uconn:// links opening the app) --------------

  late final _inviteLinks = InviteLinks((link) => unawaited(_onInviteLink(link)));

  /// An invite link that arrived before the rendezvous server was set: the
  /// connect page fills it in (see takePendingInvite).
  String? _pendingInvite;

  String? takePendingInvite() {
    final link = _pendingInvite;
    _pendingInvite = null;
    return link;
  }

  void _tell(String text) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _onInviteLink(String raw) async {
    final link = raw.trim();
    final creds = TopicCreds.parse(link);
    if (creds == null) {
      _tell('That is not a valid uConnect invite link.');
      return;
    }
    final current = TopicCreds.parse(store.topicUri);
    if (current != null && current.idHex == creds.idHex && store.topicUri == link) {
      _tell('You are already in this topic.');
      return;
    }
    // First run: no server yet, so the link alone cannot connect. Hand it to
    // the connect page, which asks for the server.
    if (store.server.isEmpty) {
      _pendingInvite = link;
      notifyListeners();
      return;
    }
    if (store.topicUri.isNotEmpty) {
      final context = navigatorKey.currentContext;
      if (context == null) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Join this topic?'),
          content: Text(
            'Topic ${creds.idHex.substring(0, 8)} from the scanned invite. '
            'This phone leaves the topic it is in now.',
            style: TextStyle(color: UcColors.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Join'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await saveSettings(topicUri: link);
    await connect();
    if (startError.isEmpty) {
      _tell('Joined topic ${creds.idHex.substring(0, 8)}.');
    }
  }

  void _applyLocalConfig() {
    storageOfferer.offered = store.offerStorage;
    storageOfferer.shares = store.shares;
    final screenOn = store.offerScreen && capture.supported;
    final controlOn = store.offerControl && _controlAvailable;
    final cameraOn = store.offerCamera && cameraCapture.supported;
    screenHost.offered = screenOn;
    screenHost.offerControl = controlOn;
    cameraHost.offered = cameraOn;
    cameraCapture.offeredIds = store.cameraOffered;
    cameraHost.maxWidthCap = store.cameraMaxWidth;
    cameraHost.maxFpsCap = store.cameraMaxFps;
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
        if (cameraOn) Services.camera,
      ],
    ));
    session.setAccessPolicy(AccessPolicy(
      defaults: normalizePermissions(store.defaultPermissions),
      special: {
        for (final t in store.special.values)
          t.keyHex: normalizePermissions(t.permissions)
      },
      rules: networkRules,
      localAddresses: localAddresses,
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
        relayMode: store.relayMode,
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
    bool? offerCamera,
    Set<String>? cameraOffered,
    int? cameraMaxWidth,
    int? cameraMaxFps,
    int? relayMode,
    int? screenMaxWidth,
    int? screenMaxFps,
    String? colorScheme,
  }) async {
    if (server != null) store.server = server.trim();
    if (topicUri != null) store.topicUri = topicUri.trim();
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      store.deviceName = deviceName.trim();
    }
    if (offerStorage != null) store.offerStorage = offerStorage;
    if (offerScreen != null) store.offerScreen = offerScreen;
    if (offerControl != null) store.offerControl = offerControl;
    if (offerCamera != null) store.offerCamera = offerCamera;
    if (cameraOffered != null) store.cameraOffered = cameraOffered;
    if (cameraMaxWidth != null) store.cameraMaxWidth = cameraMaxWidth;
    if (cameraMaxFps != null) store.cameraMaxFps = cameraMaxFps;
    if (relayMode != null) store.relayMode = relayMode;
    if (screenMaxWidth != null) store.screenMaxWidth = screenMaxWidth;
    if (screenMaxFps != null) store.screenMaxFps = screenMaxFps;
    if (colorScheme != null) store.colorScheme = colorScheme;
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
      {bool control = false, bool camera = false}) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    final title = control
        ? 'Let it control your device?'
        : camera
            ? 'Share your camera?'
            : 'Share your screen?';
    final body = control
        ? '"$name" is asking to control this device — tap, swipe, scroll '
            'and type — while it watches your screen.'
        : camera
            ? '"$name" is asking to watch this device\'s camera.'
            : '"$name" is asking to watch this device\'s screen. While you '
                'share, it sees everything on your screen.';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body, style: TextStyle(color: UcColors.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // --- permissions: special rules, network rules, defaults ---------------------

  // What a device with this key may do here right now (a network rule's or
  // the defaults), as shown for it: where its special rules start from.
  Set<String> _currentPermissionsOf(String keyHex) {
    for (final p in session.peers.values) {
      if (p.identityKey == keyHex) return p.permissions.toSet();
    }
    return withoutSensitive(normalizePermissions(store.defaultPermissions));
  }

  /// Gives a device special rules, starting from what it may do now.
  Future<void> addSpecialRules(String keyHex, String name) async {
    store.special.putIfAbsent(
        keyHex, () => SpecialRules(keyHex, name, _currentPermissionsOf(keyHex)));
    await store.save();
    _applyLocalConfig();
  }

  /// Drops a device's special rules: network rules and defaults apply again.
  Future<void> removeSpecialRules(String keyHex) async {
    store.special.remove(keyHex);
    await store.save();
    _applyLocalConfig();
  }

  /// Sets a device's special rules (adding them if it had none).
  Future<void> setSpecialPermissions(String keyHex, String name, Set<String> perms) async {
    final t = store.special
        .putIfAbsent(keyHex, () => SpecialRules(keyHex, name, <String>{}));
    t.permissions = perms;
    await store.save();
    _applyLocalConfig();
  }

  Future<void> setDefaultPermissions(Set<String> perms) async {
    store.defaultPermissions = withoutSensitive(perms);
    await store.save();
    _applyLocalConfig();
  }

  /// The joined topic's id, which network rules are kept under.
  String get topicKey => TopicCreds.parse(store.topicUri)?.idHex ?? '';

  /// This topic's network rules, first match wins.
  List<NetworkRule> get networkRules => store.networkRules[topicKey] ?? const [];

  Future<void> setNetworkRules(List<NetworkRule> rules) async {
    final key = topicKey;
    if (key.isEmpty) return;
    store.networkRules[key] = rules.take(maxNetworkRules).toList();
    await store.save();
    _applyLocalConfig();
  }

  /// Asks a connected device for its network rules on this topic; its answer
  /// comes on [networkRulesOffers].
  void requestNetworkRules(String dev) => session.requestNetworkRules(dev);
  Stream<NetworkRulesOffer> get networkRulesOffers => session.networkRulesOffers;

  /// This device's IPv4 addresses, for the rules' "m" parts; refreshed now
  /// and then, as they change with the network.
  List<InternetAddress> localAddresses = const [];
  Timer? _addressTimer;

  Future<void> _refreshLocalAddresses() async {
    final now = await localIpv4Addresses();
    final same = now.length == localAddresses.length &&
        now.every((a) => localAddresses.any((b) => b.address == a.address));
    if (same) return;
    localAddresses = now;
    _applyLocalConfig();
    notifyListeners();
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
    unawaited(cameraHost.stop());
    unawaited(session.stop());
  }

  @override
  void dispose() {
    _addressTimer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_background.stop());
    unawaited(screenHost.dispose());
    unawaited(cameraHost.dispose());
    storageOfferer.dispose();
    unawaited(session.dispose());
    super.dispose();
  }
}
