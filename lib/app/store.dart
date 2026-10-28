// Persistent app state, one JSON file in the app's private storage: the
// server, the joined topic, this device's name and offered services, the
// permission defaults, special rules per device, network rules per topic,
// and the shared folders. The
// identity seed lives in its own file (identity.dart), not here.

import 'dart:convert';
import 'dart:io';

import '../core/network_rules.dart';
import '../core/permissions.dart';
import '../core/sync/sync_folder.dart';

import '../core/storage/storage_offerer.dart';

/// How the connection may use the server's relay.
///  - [auto]: connect directly when possible, fall back to the relay.
///  - [always]: skip NAT punching and always go through the relay.
///  - [direct]: never relay the media; a direct path is required for it
///    (the tiny control channel may still relay — the library always keeps
///    that fallback — but no screen/file data goes through the server).
class RelayMode {
  static const auto = 0;
  static const always = 1;
  static const direct = 2;

  static const labels = ['Auto', 'Always relay', 'Direct only'];
  static const blurbs = [
    'Direct when possible, through the relay when it is not.',
    'Skip NAT punching; for networks where direct is known to fail.',
    'Never send media through the relay; needs a direct connection.',
  ];
}

/// Special rules: permissions set for one device, by the public key it proves
/// (see Session.resolvePermissions). They add to what its network rule and
/// the defaults grant it, unless they are an exception: then only they apply.
class SpecialRules {
  SpecialRules(this.keyHex, this.name, this.permissions, {this.exception = false});
  final String keyHex;
  String name; // what it called itself when they were added; a label only
  Set<String> permissions;
  bool exception;

  Map<String, Object?> toJson() => {
        'key': keyHex,
        'name': name,
        'perms': permissions.toList()..sort(),
        'exception': exception,
      };

  /// [defaults] decides rules saved before they added up (no "exception"):
  /// they stay an exception where that keeps a default away from the device.
  static SpecialRules? fromJson(Object? v, {Set<String> defaults = const {}}) {
    if (v is! Map) return null;
    final key = v['key'];
    if (key is! String) return null;
    final perms = <String>{
      if (v['perms'] is List)
        for (final p in v['perms'] as List)
          if (p is String) p
    };
    final normalized = normalizePermissions(perms);
    return SpecialRules(
      key,
      v['name'] is String ? v['name'] as String : '',
      perms,
      exception: v['exception'] is bool
          ? v['exception'] as bool
          : normalizePermissions(defaults).any((p) => !normalized.contains(p)),
    );
  }
}

class AppStore {
  AppStore(this.path);

  final String path;

  String server = '';
  String topicUri = '';

  /// The invite link of the topic last left, offered again on the connect page.
  String lastTopicUri = '';
  String deviceName = '';
  bool offerStorage = true;
  bool offerScreen = false;
  bool offerControl = false;
  bool offerCamera = false;
  int relayMode = RelayMode.auto;
  bool get forceRelay => relayMode == RelayMode.always;
  // What to ask for when watching another device's screen or camera (Settings
  // > Watching; a view's quality sheet changes them): width, frame rate, a
  // bitrate cap (0 = the other device's limit) and the playback buffer.
  int screenMaxWidth = 1920;
  int screenMaxFps = 60;
  int viewBitrate = 0;
  int viewBufferMs = -1; // -1: automatic, following the network
  // Limits on sharing this phone's screen (Settings > Screen sharing): width
  // (0 = the screen's own), frame rate and bitrate.
  int screenShareMaxWidth = 0;
  int screenShareMaxFps = 60;
  int screenShareMaxBitrate = 16000000;
  // Camera source settings: which of this device's cameras to offer (empty =
  // all), and the top resolution/frame rate to encode at (bounded further by
  // what the physical camera supports). A viewer picks within these.
  Set<String> cameraOffered = {};
  int cameraMaxWidth = 1280;
  int cameraMaxFps = 30;
  int cameraMaxBitrate = 16000000;
  Set<String> defaultPermissions = {};
  final special = <String, SpecialRules>{}; // key hex -> its special rules
  // Network rules, per topic id (hex): first match wins (core/network_rules).
  final networkRules = <String, List<NetworkRule>>{};
  // Synced folders (core/sync): where each is here, and who takes part.
  List<FolderConfig> syncFolders = [];
  // When folder sync may run, and whether its problems are notified.
  bool syncWifiOnly = false;
  bool syncChargingOnly = false;
  bool syncNotify = true;
  List<SharedFolder> shares = [];
  // Colour scheme id (see ui/theme.dart): system, dark, darker, light, colorful.
  String colorScheme = 'dark';

  Future<void> load() async {
    final file = File(path);
    if (!await file.exists()) return;
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object {
      return; // unreadable state: start fresh rather than crash
    }
    if (decoded is! Map) return;
    server = decoded['server'] is String ? decoded['server'] as String : '';
    topicUri = decoded['topic'] is String ? decoded['topic'] as String : '';
    lastTopicUri =
        decoded['lastTopic'] is String ? decoded['lastTopic'] as String : '';
    deviceName =
        decoded['deviceName'] is String ? decoded['deviceName'] as String : '';
    offerStorage = decoded['offerStorage'] is bool
        ? decoded['offerStorage'] as bool
        : true;
    offerScreen = decoded['offerScreen'] == true;
    offerControl = decoded['offerControl'] == true;
    offerCamera = decoded['offerCamera'] == true;
    cameraOffered = {
      if (decoded['cameraOffered'] is List)
        for (final c in decoded['cameraOffered'] as List)
          if (c is String) c
    };
    cameraMaxWidth =
        decoded['cameraMaxWidth'] is int ? decoded['cameraMaxWidth'] as int : 1280;
    cameraMaxFps =
        decoded['cameraMaxFps'] is int ? decoded['cameraMaxFps'] as int : 30;
    relayMode = decoded['relayMode'] is int
        ? (decoded['relayMode'] as int).clamp(RelayMode.auto, RelayMode.direct)
        : (decoded['forceRelay'] == true ? RelayMode.always : RelayMode.auto);
    screenMaxWidth =
        decoded['screenMaxWidth'] is int ? decoded['screenMaxWidth'] as int : 1920;
    screenMaxFps =
        decoded['screenMaxFps'] is int ? decoded['screenMaxFps'] as int : 60;
    final values = decoded;  // keeps its checked type inside the closure
    int number(String key, int fallback) =>
        values[key] is int ? values[key] as int : fallback;
    viewBitrate = number('viewBitrate', 0);
    viewBufferMs = number('viewBufferMs', -1);
    screenShareMaxWidth = number('screenShareMaxWidth', 0);
    screenShareMaxFps = number('screenShareMaxFps', 60);
    screenShareMaxBitrate = number('screenShareMaxBitrate', 16000000);
    cameraMaxBitrate = number('cameraMaxBitrate', 16000000);
    syncWifiOnly = decoded['syncWifiOnly'] == true;
    syncChargingOnly = decoded['syncChargingOnly'] == true;
    syncNotify = decoded['syncNotify'] != false;
    colorScheme = decoded['colorScheme'] is String
        ? decoded['colorScheme'] as String
        : 'dark';
    defaultPermissions = {
      if (decoded['defaults'] is List)
        for (final p in decoded['defaults'] as List)
          if (p is String) p
    };
    special.clear();
    // Before special rules there was trust; a trusted device's own permissions
    // are exactly its special rules.
    for (final list in [decoded['trusted'], decoded['special']]) {
      if (list is! List) continue;
      for (final t in list) {
        final d = SpecialRules.fromJson(t, defaults: defaultPermissions);
        if (d != null) special[d.keyHex] = d;
      }
    }
    syncFolders = [
      if (decoded['sync'] is List)
        for (final f in decoded['sync'] as List)
          if (folderConfigFromJson(f) case final c?) c
    ];
    networkRules.clear();
    final rules = decoded['networkRules'];
    if (rules is Map) {
      for (final e in rules.entries) {
        if (e.key is String) networkRules[e.key as String] = networkRulesFromJson(e.value);
      }
    }
    shares = [
      if (decoded['shares'] is List)
        for (final s in decoded['shares'] as List)
          if (s is Map && s['name'] is String && s['path'] is String)
            SharedFolder(s['name'] as String, s['path'] as String,
                readOnly: s['readOnly'] == true)
    ];
  }

  Future<void> save() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final data = <String, Object?>{
      'server': server,
      'topic': topicUri,
      'lastTopic': lastTopicUri,
      'deviceName': deviceName,
      'offerStorage': offerStorage,
      'offerScreen': offerScreen,
      'offerControl': offerControl,
      'offerCamera': offerCamera,
      'cameraOffered': cameraOffered.toList()..sort(),
      'cameraMaxWidth': cameraMaxWidth,
      'cameraMaxFps': cameraMaxFps,
      'relayMode': relayMode,
      'screenMaxWidth': screenMaxWidth,
      'screenMaxFps': screenMaxFps,
      'viewBitrate': viewBitrate,
      'viewBufferMs': viewBufferMs,
      'screenShareMaxWidth': screenShareMaxWidth,
      'screenShareMaxFps': screenShareMaxFps,
      'screenShareMaxBitrate': screenShareMaxBitrate,
      'cameraMaxBitrate': cameraMaxBitrate,
      'colorScheme': colorScheme,
      'defaults': defaultPermissions.toList()..sort(),
      'special': [for (final t in special.values) t.toJson()],
      'sync': [for (final f in syncFolders) folderConfigToJson(f)],
      'syncWifiOnly': syncWifiOnly,
      'syncChargingOnly': syncChargingOnly,
      'syncNotify': syncNotify,
      'networkRules': {
        for (final e in networkRules.entries)
          if (e.value.isNotEmpty) e.key: networkRulesToJson(e.value)
      },
      'shares': [
        for (final s in shares)
          {'name': s.name, 'path': s.path, 'readOnly': s.readOnly}
      ],
    };
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(path);
  }
}

Map<String, Object?> folderConfigToJson(FolderConfig c) => {
      'id': c.id,
      'label': c.label,
      'path': c.path,
      'paused': c.paused,
      'peers': {
        for (final e in c.peers.entries)
          e.key: {
            'receive': e.value.receive,
            'contribute': e.value.contribute,
            'paused': e.value.paused,
          }
      },
    };

FolderConfig? folderConfigFromJson(Object? v) {
  if (v is! Map || v['id'] is! String || v['path'] is! String) return null;
  final peers = <String, Grant>{};
  if (v['peers'] is Map) {
    for (final e in (v['peers'] as Map).entries) {
      final g = e.value;
      if (e.key is String && g is Map) {
        peers[e.key as String] = Grant(
            receive: g['receive'] == true,
            contribute: g['contribute'] == true,
            paused: g['paused'] == true);
      }
    }
  }
  return FolderConfig(
      id: v['id'] as String,
      label: v['label'] is String ? v['label'] as String : '',
      path: v['path'] as String,
      paused: v['paused'] == true,
      peers: peers);
}
