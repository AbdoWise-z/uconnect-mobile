// Persistent app state, one JSON file in the app's private storage: the
// server, the joined topic, this device's name and offered services, the
// permission defaults, every trusted device, and the shared folders. The
// identity seed lives in its own file (identity.dart), not here.

import 'dart:convert';
import 'dart:io';

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

class TrustedDevice {
  TrustedDevice(this.keyHex, this.name, this.permissions);
  final String keyHex;
  String name; // what it called itself when trusted; a label, nothing more
  Set<String> permissions;

  Map<String, Object?> toJson() => {
        'key': keyHex,
        'name': name,
        'perms': permissions.toList()..sort(),
      };

  static TrustedDevice? fromJson(Object? v) {
    if (v is! Map) return null;
    final key = v['key'];
    if (key is! String) return null;
    return TrustedDevice(
      key,
      v['name'] is String ? v['name'] as String : '',
      {
        if (v['perms'] is List)
          for (final p in v['perms'] as List)
            if (p is String) p
      },
    );
  }
}

class AppStore {
  AppStore(this.path);

  final String path;

  String server = '';
  String topicUri = '';
  String deviceName = '';
  bool offerStorage = true;
  bool offerScreen = false;
  bool offerControl = false;
  bool offerCamera = false;
  int relayMode = RelayMode.auto;
  bool get forceRelay => relayMode == RelayMode.always;
  // Quality to ask for when watching another device's screen. The default is
  // full; the viewer lets the user pick a lower one when the phone's decoder
  // cannot keep up (see ScreenQuality in ui/screen_view.dart).
  int screenMaxWidth = 1920;
  int screenMaxFps = 60;
  Set<String> defaultPermissions = {};
  final trusted = <String, TrustedDevice>{}; // key hex -> device
  List<SharedFolder> shares = [];

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
    deviceName =
        decoded['deviceName'] is String ? decoded['deviceName'] as String : '';
    offerStorage = decoded['offerStorage'] is bool
        ? decoded['offerStorage'] as bool
        : true;
    offerScreen = decoded['offerScreen'] == true;
    offerControl = decoded['offerControl'] == true;
    offerCamera = decoded['offerCamera'] == true;
    relayMode = decoded['relayMode'] is int
        ? (decoded['relayMode'] as int).clamp(RelayMode.auto, RelayMode.direct)
        : (decoded['forceRelay'] == true ? RelayMode.always : RelayMode.auto);
    screenMaxWidth =
        decoded['screenMaxWidth'] is int ? decoded['screenMaxWidth'] as int : 1920;
    screenMaxFps =
        decoded['screenMaxFps'] is int ? decoded['screenMaxFps'] as int : 60;
    defaultPermissions = {
      if (decoded['defaults'] is List)
        for (final p in decoded['defaults'] as List)
          if (p is String) p
    };
    trusted.clear();
    if (decoded['trusted'] is List) {
      for (final t in decoded['trusted'] as List) {
        final d = TrustedDevice.fromJson(t);
        if (d != null) trusted[d.keyHex] = d;
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
      'deviceName': deviceName,
      'offerStorage': offerStorage,
      'offerScreen': offerScreen,
      'offerControl': offerControl,
      'offerCamera': offerCamera,
      'relayMode': relayMode,
      'screenMaxWidth': screenMaxWidth,
      'screenMaxFps': screenMaxFps,
      'defaults': defaultPermissions.toList()..sort(),
      'trusted': [for (final t in trusted.values) t.toJson()],
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
