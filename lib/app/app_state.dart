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
import '../core/sync/sync_client.dart';
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
import '../ui/format.dart';
import '../ui/theme.dart';
import 'background.dart';
import 'invite_links.dart';
import 'store.dart';
import 'sync_platform.dart';

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
  late final power = PowerConditions(_applySyncConditions);
  final syncNotifier = SyncNotifier();

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
    await _migrateSyncPermissions();
    _startSync();
    _applyLocalConfig();
    screenHost.offered = store.offerScreen;
    cameraHost.offered = store.offerCamera && cameraCapture.supported;
    _controlAvailable = await input.available();
    _subs.add(session.changed.listen((_) {
      _syncBackgroundService();
      notifyListeners();
    }));
    unawaited(power.start());
    unawaited(refreshBackgroundStatus());
    _applySyncConditions();
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

  late final _inviteLinks = InviteLinks((link) => unawaited(handleInviteLink(link)));

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

  /// Joins the topic of an invite link: one scanned from a QR code (the
  /// scanner page, or the system camera opening the app), or a tapped link.
  Future<void> handleInviteLink(String raw) async {
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
    // Any permission change may change who syncs; told once the policy
    // below is in place.
    Future.microtask(_resyncPeers);
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
  // Whether the user wants to be connected: the keep-alive service runs for
  // as long as this holds, through drops and reconnects. Stopping it on a
  // drop and starting it again on reconnect does not work: Android 12+
  // refuses a foreground service started from the background, and the app
  // would then be frozen until opened again.
  bool _wantConnected = false;
  bool _backgroundRefused = false;
  bool? _batteryExempt;

  /// The system refused the keep-alive service; the app stays connected only
  /// while open.
  bool get backgroundRefused => _backgroundRefused;

  /// True when Android will not put the app to sleep; null where unknown or
  /// not applicable.
  bool? get batteryExempt => _batteryExempt;

  void _syncBackgroundService() {
    final status = session.status;
    var text = switch (status) {
      SessionStatus.online => () {
          final n = session.peers.values.where((p) => p.stateCode == 3).length;
          return n == 0
              ? 'Connected · waiting for your devices'
              : 'Connected to $n device${n == 1 ? '' : 's'}';
        }(),
      SessionStatus.connecting ||
      SessionStatus.reconnecting =>
        'Connecting to your devices…',
      SessionStatus.offline ||
      SessionStatus.error =>
        _wantConnected ? 'Not connected · will reconnect' : '',
    };
    final syncing = text.isEmpty ? '' : syncSummary();
    if (syncing.isNotEmpty) text = '$text · $syncing';
    if (text.isEmpty) {
      _lastBgText = '';
      _background.stop();
    } else if (text != _lastBgText) {
      _lastBgText = text;
      unawaited(_background.start(text).then((ok) {
        if (_backgroundRefused == ok) {
          _backgroundRefused = !ok;
          notifyListeners();
        }
      }));
    }
  }

  /// Re-reads whether the app is exempt from battery optimisation (the user
  /// may have just changed it in the system prompt).
  Future<void> refreshBackgroundStatus() async {
    final exempt = await _background.isExemptFromBatteryOptimizations();
    if (exempt != _batteryExempt) {
      _batteryExempt = exempt;
      notifyListeners();
    }
  }

  Future<void> requestBatteryExemption() => _background.requestBatteryExemption();

  Future<void> connect() async {
    startError = '';
    _wantConnected = true;
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
    _wantConnected = false;
    await session.stop();
    _syncBackgroundService();
    notifyListeners();
  }

  /// Leaves the topic: disconnects, stops sharing, and forgets the link (kept
  /// as [AppStore.lastTopicUri] to rejoin), so the app shows the connect page.
  Future<void> leaveTopic() async {
    _wantConnected = false;
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
    bool? syncWifiOnly,
    bool? syncChargingOnly,
    bool? syncNotify,
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
    if (syncWifiOnly != null) store.syncWifiOnly = syncWifiOnly;
    if (syncChargingOnly != null) store.syncChargingOnly = syncChargingOnly;
    if (syncNotify != null) store.syncNotify = syncNotify;
    await store.save();
    _applyLocalConfig();
    _applySyncConditions();
    notifyListeners();
  }

  // "Only on Wi-Fi" / "only while charging": every folder waits while a
  // condition the user set does not hold.
  void _applySyncConditions() {
    if (!loaded && !_syncStarted) return;
    final reason = store.syncWifiOnly && power.known && !power.wifi
        ? 'wifi'
        : store.syncChargingOnly && power.known && !power.charging
            ? 'charging'
            : '';
    if (sync.suspended != reason) {
      sync.suspended = reason;
      _syncBackgroundService();
      notifyListeners();
    }
  }

  /// A short line on what sync is doing across folders, or empty when there
  /// is nothing to say ("Syncing 3 files, 12 MB left", "Waiting for Wi-Fi").
  String syncSummary() {
    if (store.syncFolders.isEmpty) return '';
    if (sync.suspended == 'wifi') return 'Waiting for Wi-Fi';
    if (sync.suspended == 'charging') return 'Waiting for the charger';
    var files = 0, bytes = 0, conflicts = 0, deletes = 0;
    for (final c in store.syncFolders) {
      final st = sync.folderStatus(c.id);
      files += (st['needFiles'] as num?)?.toInt() ?? 0;
      bytes += (st['needBytes'] as num?)?.toInt() ?? 0;
      conflicts += (st['conflicts'] as List?)?.length ?? 0;
      deletes += (st['pendingDeleteCount'] as num?)?.toInt() ?? 0;
    }
    final parts = <String>[];
    if (files > 0) parts.add('Syncing $files file${files == 1 ? '' : 's'}, ${formatBytes(bytes)} left');
    if (conflicts > 0) parts.add('$conflicts conflict${conflicts == 1 ? '' : 's'}');
    if (deletes > 0) parts.add('$deletes delete${deletes == 1 ? '' : 's'} waiting for you');
    return parts.join(' · ');
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

  late final SyncClient sync;

  /// Folders other devices offer this phone, by their key: [{id, label}].
  final syncOffers = <String, List<Map<String, String>>>{};

  /// Recent sync events, newest first, with when they happened.
  final syncEvents = <SyncEvent>[];
  bool _syncStarted = false;
  // Per member: the sizes it was behind by, and since when, for "stays
  // behind" notifications.
  final _behind = <String, (int, int)>{}; // key -> (signature, since ms)

  void _startSync() {
    _syncStarted = true;
    // The engine runs on its own isolate (SyncClient): a large folder's
    // planning, hashing and listing never hold up the UI.
    sync = SyncClient(
      sendControl: (dev, msg) => session.sendControl(dev, msg),
      sendData: (dev, id, bytes) =>
          session.sendFrame(dev, MessageKind.syncData, id, bytes),
      // A proven peer takes part once it is granted Offer sync or Receive
      // sync here (from any layer: special rules, a network rule or the
      // defaults); each folder's grants then name what it is sent and
      // taken from.
      peerKey: (dev) {
        final p = session.peers[dev];
        return p != null &&
                p.identityState == 'verified' &&
                syncsWith(session.permissionsFor(dev))
            ? p.identityKey
            : null;
      },
      offersTo: (dev) => session.permissionsFor(dev).contains(Perm.syncOffer),
      connectedSince: (dev) => session.peers[dev]?.connectedAt ?? -1,
      myKeyHex: identity!.publicKeyHex,
      stateDir: '$dataDir${Platform.pathSeparator}sync',
      freeSpace: freeSpaceOf,
      onError: (m) => debugPrint('sync worker: $m'),
    );
    unawaited(sync.start());
    session.addControlHandler(sync.handleControl);
    session.setFrameHandler(MessageKind.syncData, sync.handleData);
    session.addIdentityHandler(sync.peerUp);
    session.addPeerStateHandler((dev, state) {
      if (state == ucPeerClosed || state == ucPeerFailed) sync.peerGone(dev);
    });
    _subs.add(sync.offers.listen((o) {
      // Shown only from a device granted Receive sync here.
      if (o.folders.isEmpty || !mayReceiveSyncFrom(o.peerKey)) {
        syncOffers.remove(o.peerKey);
      } else {
        syncOffers[o.peerKey] = o.folders;
      }
      notifyListeners();
    }));
    _subs.add(sync.folderChanged.listen((id) {
      _watchBehind(id);
      _syncBackgroundService();
      notifyListeners();
    }));
    _subs.add(sync.events.listen((e) {
      syncEvents.insert(0, e);
      if (syncEvents.length > 200) syncEvents.removeLast();
      _notifySyncEvent(e);
      notifyListeners();
    }));
    sync.setFolders(store.syncFolders);
  }

  String _folderLabel(String id) {
    final c = syncFolder(id);
    return c == null || c.label.isEmpty ? 'Synced folder' : c.label;
  }

  void _notifySyncEvent(SyncEvent e) {
    if (!store.syncNotify) return;
    final label = _folderLabel(e.folderId);
    if (e.kind == 'conflict') {
      unawaited(syncNotifier.show('conflict|${e.folderId}|${e.path}', '$label: conflict',
          'Your change to ${e.path} conflicts with another device\'s. Choose which to keep.'));
    } else if (e.kind.startsWith('held:')) {
      unawaited(syncNotifier.show('held|${e.folderId}|${e.path}', '$label: not synced',
          '${e.path} has a name not every device can hold. Rename it to sync it.'));
    } else if (e.kind.startsWith('deletes:')) {
      final n = e.kind.substring(8);
      unawaited(syncNotifier.show('deletes|${e.folderId}|$n', '$label: $n deletes waiting',
          'Another device removed $n files at once. Open the folder to delete them here too, or keep them.'));
    }
  }

  // A device online that stays behind by the same amount for 15 minutes.
  void _watchBehind(String folderId) {
    final st = sync.folderStatus(folderId);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final m in (st['members'] as List?) ?? const []) {
      if (m is! Map) continue;
      final key = '$folderId|${m['key']}';
      final left = ((m['toSendBytes'] as num?)?.toInt() ?? 0) +
          ((m['toReceiveBytes'] as num?)?.toInt() ?? 0) +
          ((m['toSendFiles'] as num?)?.toInt() ?? 0) +
          ((m['toReceiveFiles'] as num?)?.toInt() ?? 0);
      if (m['online'] != true || left == 0) {
        _behind.remove(key);
        continue;
      }
      final was = _behind[key];
      if (was == null || was.$1 != left) {
        _behind[key] = (left, now);
      } else if (now - was.$2 >= 15 * 60 * 1000 && store.syncNotify) {
        unawaited(syncNotifier.show('behind|$key', '${_folderLabel(folderId)}: a device stays behind',
            '${deviceNameForKey('${m['key']}')} has not caught up for 15 minutes.'));
      }
    }
  }

  Future<void> _saveSyncFolders(List<FolderConfig> folders) async {
    store.syncFolders = folders;
    await store.save();
    sync.setFolders(folders);
    _resyncPeers();
    notifyListeners();
  }

  // Permissions may have changed: let connected, proven peers hear about it
  // (one that lost both sync permissions drops out of sync; one that gained
  // Offer sync is told its folders). Offers already shown are checked again.
  void _resyncPeers() {
    if (!_syncStarted) return;
    syncOffers.removeWhere((key, _) => !mayReceiveSyncFrom(key));
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

  /// What a device with this key is granted here, as far as is known: for a
  /// connected peer every layer, otherwise its special rules and the defaults
  /// (a network rule needs its address).
  Set<String> permissionsOfKey(String key) {
    for (final p in session.peers.values) {
      if (p.identityKey == key && p.identityState == 'verified') {
        return session.permissionsFor(p.devId);
      }
    }
    return {
      ...normalizePermissions(store.defaultPermissions),
      ...?store.special[key]?.permissions,
    };
  }

  /// Whether a device's folder offers are shown here (Receive sync).
  bool mayReceiveSyncFrom(String key) =>
      permissionsOfKey(key).contains(Perm.syncReceive);

  /// Devices that can be made members of a folder: those granted Offer sync
  /// or Receive sync here, as far as is known (special rules, connected
  /// peers), plus anyone already a member.
  List<String> syncCandidates(FolderConfig c) {
    final keys = <String>{...c.peers.keys};
    for (final key in store.special.keys) {
      if (syncsWith(permissionsOfKey(key))) keys.add(key);
    }
    for (final p in session.peers.values) {
      if (p.identityState == 'verified' &&
          p.identityKey.isNotEmpty &&
          syncsWith(session.permissionsFor(p.devId))) {
        keys.add(p.identityKey);
      }
    }
    keys.remove('');
    return keys.toList()
      ..sort((a, b) => deviceNameForKey(a).compareTo(deviceNameForKey(b)));
  }

  /// Joins a folder a proven device offers: it is sent here and accepted from.
  Future<bool> joinSyncFolder(String peerKey, String id, String label, String path) async {
    if (syncFolder(id) != null || !mayReceiveSyncFrom(peerKey)) return false;
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
      peers[key] = Grant(
          receive: receive, contribute: contribute, paused: c.grantOf(key).paused);
    }
    await _replaceSyncFolder(_with(c, peers: peers));
  }

  /// Pauses one device in a folder: its grants stay, but nothing is sent to
  /// it or taken from it until it is resumed.
  Future<void> setSyncMemberPaused(String id, String key, bool paused) async {
    final c = syncFolder(id);
    final g = c?.peers[key];
    if (c == null || g == null || g.paused == paused) return;
    await _replaceSyncFolder(_with(c, peers: {
      ...c.peers,
      key: Grant(receive: g.receive, contribute: g.contribute, paused: paused),
    }));
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

  // Before sync 1.3 a device took part by having special rules; now it needs
  // Offer sync or Receive sync. Once: every member of a synced folder that
  // has special rules and neither permission gets both, so nothing stops
  // syncing on update.
  Future<void> _migrateSyncPermissions() async {
    if (store.syncPermsMigrated) return;
    var changed = false;
    for (final c in store.syncFolders) {
      for (final key in c.peers.keys) {
        final t = store.special[key];
        if (t == null || syncsWith(t.permissions)) continue;
        t.permissions = {...t.permissions, Perm.syncOffer, Perm.syncReceive};
        changed = true;
      }
    }
    store.syncPermsMigrated = true;
    if (changed || store.syncFolders.isNotEmpty || store.special.isNotEmpty) await store.save();
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
    _wantConnected = false;
    session.stopNow();
    unawaited(_background.stop());
    unawaited(screenHost.stop());
    unawaited(cameraHost.stop());
    unawaited(session.stop());
  }

  @override
  void dispose() {
    unawaited(power.dispose());
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
