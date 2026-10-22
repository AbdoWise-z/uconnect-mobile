// The app-level wire format between uConnect apps, as specified by
// uconnect-desktop's docs/protocol.md (section 2): every message is
// [u8 kind][payload]. Kind 1 is a compact UTF-8 JSON object whose "t" names
// its type; kinds 2-4 carry binary frames with a big-endian u32 request id.

import 'dart:convert';
import 'dart:typed_data';

class MessageKind {
  static const int control = 1;
  static const int data = 2; // storage download data
  static const int storageUploadData = 3;
  static const int syncData = 4;
}

/// Service names carried in hello's `svc`, in the desktop app's order.
class Services {
  static const storage = 'storage';
  static const camera = 'camera';
  static const screen = 'screen';
  static const control = 'control';
  static const display = 'display';
  static const all = [storage, camera, screen, control, display];
}

Uint8List encodeControl(Map<String, Object?> message) {
  final json = utf8.encode(jsonEncode(message));
  final out = Uint8List(1 + json.length);
  out[0] = MessageKind.control;
  out.setAll(1, json);
  return out;
}

/// The JSON object of a kind-1 message, or null for anything else (other
/// kinds, malformed JSON, or a payload that is not an object).
Map<String, Object?>? decodeControl(Uint8List message) {
  if (message.isEmpty || message[0] != MessageKind.control) return null;
  try {
    final decoded = jsonDecode(utf8.decode(message.sublist(1)));
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// A kind 2/3/4 frame: [u8 kind][u32 id, big endian][bytes].
Uint8List encodeDataFrame(int kind, int id, List<int> bytes) {
  final out = Uint8List(5 + bytes.length);
  out[0] = kind;
  ByteData.view(out.buffer).setUint32(1, id, Endian.big);
  out.setAll(5, bytes);
  return out;
}

class DataFrame {
  DataFrame(this.kind, this.id, this.bytes);
  final int kind;
  final int id;
  final Uint8List bytes;
}

DataFrame? decodeDataFrame(Uint8List message) {
  if (message.length < 5) return null;
  final kind = message[0];
  if (kind != MessageKind.data &&
      kind != MessageKind.storageUploadData &&
      kind != MessageKind.syncData) {
    return null;
  }
  final id = ByteData.view(message.buffer, message.offsetInBytes + 1, 4)
      .getUint32(0, Endian.big);
  return DataFrame(kind, id, Uint8List.sublistView(message, 5));
}

/// The first message each side sends once a peer session is up (section 3).
class Hello {
  Hello({required this.name, required this.os, required this.services});

  static const int version = 1;

  final String name;
  final String os;
  final List<String> services;

  Uint8List encode() => encodeControl({
        't': 'hello',
        'v': version,
        'name': name,
        'os': os,
        'svc': services,
      });

  /// Decodes a hello from an already-parsed control message, clamping the
  /// peer's claims to sane lengths (they are untrusted).
  static Hello? fromJson(Map<String, Object?> m) {
    if (m['t'] != 'hello') return null;
    final name = (m['name'] is String ? m['name'] as String : '');
    final os = (m['os'] is String ? m['os'] as String : '');
    final svc = <String>[
      if (m['svc'] is List)
        for (final s in m['svc'] as List)
          if (s is String && Services.all.contains(s)) s
    ];
    return Hello(
      name: name.length > 64 ? name.substring(0, 64) : name,
      os: os.length > 32 ? os.substring(0, 32) : os,
      services: svc,
    );
  }
}
