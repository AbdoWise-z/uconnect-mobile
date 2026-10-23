// Glues the pieces together for the UI: loads the store and identity, owns
// the Session and the storage services, and exposes everything as a
// ChangeNotifier the widgets listen to. The counterpart of the desktop app's
// AppController.

import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/identity.dart';
import '../core/network_rules.dart';
import '../core/sync/sync_folder.dart';
import '../core/sync/sync_service.dart';
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
    _startSync();
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
    cameraHost.maxBitrateCap = store.cameraMaxBitrate;
    screenHost.maxWidthCap = store.screenShareMaxWidth;
    screenHost.maxFpsCap = store.screenShareMaxFps;
    screenHost.maxBitrateCap = store.screenShareMaxBitrate;
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
      exceptions: {
        for (final t in store.special.values)
          if (t.exception) t.keyHex
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

  /// Leaves the topic: disconnects, stops sharing, and forgets the link (kept
  /// as [AppStore.lastTopicUri] to rejoin), so the app shows the connect page.
  Future<void> leaveTopic() async {
    await screenHost.stop();
    await cameraHost.stop();
    await session.stop();
    if (store.topicUri.isNotEmpty) store.lastTopicUri = store.topicUri;
    store.topicUri = '';
    await store.save();
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
    int? viewBitrate,
    int? viewBufferMs,
    int? screenShareMaxWidth,
    int? screenShareMaxFps,
    int? screenShareMaxBitrate,
    int? cameraMaxBitrate,
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
    if (viewBitrate != null) store.viewBitrate = viewBitrate;
    if (viewBufferMs != null) store.viewBufferMs = viewBufferMs;
    if (screenShareMaxWidth != null) store.screenShareMaxWidth = screenShareMaxWidth;
    if (screenShareMaxFps != null) store.screenShareMaxFps = screenShareMaxFps;
    if (screenShareMaxBitrate != null) store.screenShareMaxBitrate = screenShareMaxBitrate;
    if (cameraMaxBitrate != null) store.cameraMaxBitrate = cameraMaxBitrate;
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

  // --- folder sync ---------------------------------------------------------------
  // The engine (core/sync) speaks protocol section 6 with the other devices;
  // this wires it to the session and keeps the folder list in the store.

  late final SyncService sync;

  /// Folders other devices offer this phone, by their key: [{id, label}].
  final syncOffers = <String, List<Map<String, String>>>{};

  /// Recent sync events, newest first.
  final syncEvents = <SyncEvent>[];

  void _startSync() {
    sync = SyncService(
      sendControl: (dev, msg) => session.sendControl(dev, msg),
      sendData: (dev, id, bytes) =>
          session.sendFrame(dev, MessageKind.syncData, id, bytes),
      // Only a proven peer with special rules takes part (network rules and
      // defaults never reach sync); each folder's grants then name which.
      peerKey: (dev) {
        final p = session.peers[dev];
        return p != null &&
                p.identityState == 'verified' &&
                store.special.containsKey(p.identityKey)
            ? p.identityKey
            : null;
      },
      connectedSince: (dev) => session.peers[dev]?.connectedAt ?? -1,
      myKeyHex: identity!.publicKeyHex,
      stateDir: '$dataDir${Platform.pathSeparator}sync',
    );
    session.addControlHandler(sync.handleControl);
    session.setFrameHandler(MessageKind.syncData, sync.handleData);
    session.addIdentityHandler(sync.peerUp);
    session.addPeerStateHandler((dev, state) {
      if (state == ucPeerClosed || state == ucPeerFailed) sync.peerGone(dev);
    });
    _subs.add(sync.offers.listen((o) {
      if (o.folders.isEmpty) {
        syncOffers.remove(o.peerKey);
      } else {
        syncOffers[o.peerKey] = o.folders;
      }
      notifyListeners();
    }));
    _subs.add(sync.folderChanged.listen((_) => notifyListeners()));
    _subs.add(sync.events.listen((e) {
      syncEvents.insert(0, e);
      if (syncEvents.length > 200) syncEvents.removeLast();
      notifyListeners();
    }));
    sync.setFolders(store.syncFolders);
  }

  Future<void> _saveSyncFolders(List<FolderConfig> folders) async {
    store.syncFolders = folders;
    await store.save();
    sync.setFolders(folders);
    _resyncPeers();
    notifyListeners();
  }

  // Grants or special rules may have changed: let connected, proven peers
  // hear about it (one that lost its special rules drops out of sync).
  void _resyncPeers() {
    for (final p in session.peers.values) {
      if (p.stateCode == ucPeerConnected && p.identityState == 'verified') {
        sync.peerUp(p.devId);
      }
    }
  }

  FolderConfig? syncFolder(String id) {
    for (final f in store.syncFolders) {
      if (f.id == id) return f;
    }
    return null;
  }

  FolderConfig _with(FolderConfig c,
          {String? label, String? path, bool? paused, Map<String, Grant>? peers}) =>
      FolderConfig(
          id: c.id,
          label: label ?? c.label,
          path: path ?? c.path,
          paused: paused ?? c.paused,
          peers: peers ?? {...c.peers});

  Future<void> _replaceSyncFolder(FolderConfig next) => _saveSyncFolders(
      [for (final f in store.syncFolders) f.id == next.id ? next : f]);

  /// Where a synced folder goes unless the user picks one: under Sync/ in the
  /// app's own folder on shared storage (Android: Android/data/(app)/files;
  /// iOS: Documents, shown in the Files app). No storage permission needed.
  Future<String> defaultSyncDir(String label) async {
    Directory? base;
    if (Platform.isAndroid) base = await getExternalStorageDirectory();
    base ??= await getApplicationDocumentsDirectory();
    final safe = label.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return '${base.path}${Platform.pathSeparator}Sync${Platform.pathSeparator}'
        '${safe.isEmpty ? 'Folder' : safe}';
  }

  /// A new synced folder with no members yet (add them on its page).
  Future<String> createSyncFolder(String path, String label) async {
    await Directory(path).create(recursive: true);
    final rnd = Random.secure();
    final id = [for (var i = 0; i < 16; i++) rnd.nextInt(256)]
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _saveSyncFolders([
      ...store.syncFolders,
      FolderConfig(
          id: id,
          label: label.length > 100 ? label.substring(0, 100) : label,
          path: path),
    ]);
    return id;
  }

  /// Joins a folder a proven device offers: it is sent here and accepted from.
  Future<bool> joinSyncFolder(String peerKey, String id, String label, String path) async {
    if (syncFolder(id) != null || !store.special.containsKey(peerKey)) return false;
    await Directory(path).create(recursive: true);
    await _saveSyncFolders([
      ...store.syncFolders,
      FolderConfig(
          id: id,
          label: label,
          path: path,
          peers: {peerKey: const Grant(receive: true, contribute: true)}),
    ]);
    return true;
  }

  /// Send: it gets the folder and this phone's changes. Accept: this phone
  /// takes its changes. Both off removes it from the folder.
  Future<void> setSyncMember(String id, String key, {required bool receive, required bool contribute}) async {
    final c = syncFolder(id);
    if (c == null) return;
    final peers = {...c.peers};
    if (!receive && !contribute) {
      peers.remove(key);
    } else {
      peers[key] = Grant(receive: receive, contribute: contribute);
    }
    await _replaceSyncFolder(_with(c, peers: peers));
  }

  Future<void> setSyncPaused(String id, bool paused) async {
    final c = syncFolder(id);
    if (c != null) await _replaceSyncFolder(_with(c, paused: paused));
  }

  /// Stops syncing a folder; its files stay where they are.
  Future<void> leaveSyncFolder(String id) async {
    await _saveSyncFolders([for (final f in store.syncFolders) if (f.id != id) f]);
    final state = File('$dataDir${Platform.pathSeparator}sync${Platform.pathSeparator}$id.json');
    if (await state.exists()) await state.delete();
  }

  /// A name for a device key: from special rules, a connected peer, or short.
  String deviceNameForKey(String key) {
    final s = store.special[key];
    if (s != null && s.name.isNotEmpty) return s.name;
    for (final p in session.peers.values) {
      if (p.identityKey == key && p.name.isNotEmpty) return p.name;
    }
    return 'Device ${fingerprintOfHex(key).substring(0, 9)}';
  }

  // --- permissions: special rules, network rules, defaults ---------------------

  // What a device with this key may do here right now, as shown for it: what
  // an exception starts from.
  Set<String> _currentPermissionsOf(String keyHex) {
    for (final p in session.peers.values) {
      if (p.identityKey == keyHex) return p.permissions.toSet();
    }
    return normalizePermissions(store.defaultPermissions);
  }

  /// Gives a device special rules. They start empty and add to its network
  /// rule and the defaults, so nothing changes until they are edited.
  Future<void> addSpecialRules(String keyHex, String name) async {
    store.special.putIfAbsent(keyHex, () => SpecialRules(keyHex, name, <String>{}));
    await store.save();
    _applyLocalConfig();
    _resyncPeers();
  }

  /// Makes a device's special rules an exception (only they apply) or not.
  /// Turning it on takes in what the network rule and defaults granted, so
  /// nothing changes until the rules are edited.
  Future<void> setSpecialException(String keyHex, bool exception) async {
    final t = store.special[keyHex];
    if (t == null || t.exception == exception) return;
    if (exception) t.permissions = {...t.permissions, ..._currentPermissionsOf(keyHex)};
    t.exception = exception;
    await store.save();
    _applyLocalConfig();
  }

  /// Drops a device's special rules: network rules and defaults apply again.
  Future<void> removeSpecialRules(String keyHex) async {
    store.special.remove(keyHex);
    await store.save();
    _applyLocalConfig();
    _resyncPeers();
  }

  /// Sets a device's special rules (adding them if it had none).
  Future<void> setSpecialPermissions(String keyHex, String name, Set<String> perms) async {
    final t = store.special
        .putIfAbsent(keyHex, () => SpecialRules(keyHex, name, <String>{}));
    t.permissions = perms;
    await store.save();
    _applyLocalConfig();
    _resyncPeers();
  }

  Future<void> setDefaultPermissions(Set<String> perms) async {
    store.defaultPermissions = perms;
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
    // First, synchronously: the async stops below may never finish once the
    // engine is torn down, and the node would linger as a ghost device.
    session.stopNow();
    unawaited(_background.stop());
    unawaited(screenHost.stop());
    unawaited(cameraHost.stop());
    unawaited(session.stop());
  }

  @override
  void dispose() {
    _addressTimer?.cancel();
    unawaited(sync.dispose());
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
