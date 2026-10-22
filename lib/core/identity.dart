// A device's long-term identity: an Ed25519 key pair (RFC 8032), generated
// once and kept in the app's private storage. Wire format and semantics match
// uconnect-desktop's Identity (docs/protocol.md section 3):
//
//     {"t":"id", "v":1, "key":"<64 hex>", "sig":"<128 hex>"}
//
// where sig signs  "uconnect-desktop identity v1" || 0x00 ||
// channel_binding(32) || public key(32). The context string is the desktop
// one on purpose: both apps speak protocol v1, and a different string would
// split the ecosystem into apps that cannot verify each other.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../uconnect/uconnect.dart' show bytesToHex, hexToBytes;

final _ed25519 = Ed25519();

const _contextV1 = 'uconnect-desktop identity v1'; // 28 ASCII bytes

Uint8List _proofMessage(Uint8List binding, Uint8List publicKey) {
  final context = ascii.encode(_contextV1);
  final out = BytesBuilder(copy: false)
    ..add(context)
    ..addByte(0)
    ..add(binding)
    ..add(publicKey);
  return out.toBytes();
}

class Identity {
  Identity._(this._keyPair, this.publicKey);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKey; // 32 bytes

  String get publicKeyHex => bytesToHex(publicKey);
  String get fingerprint => fingerprintOf(publicKey);

  static Future<Identity> generate() async {
    final pair = await _ed25519.newKeyPair();
    final pub = await pair.extractPublicKey();
    return Identity._(pair, Uint8List.fromList(pub.bytes));
  }

  static Future<Identity> fromSeed(Uint8List seed) async {
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    return Identity._(pair, Uint8List.fromList(pub.bytes));
  }

  /// Reads the identity stored at [path], creating and storing a new one if
  /// there is none. A file that exists but cannot be used is moved aside, not
  /// overwritten.
  static Future<Identity> loadOrCreate(String path) async {
    final file = File(path);
    if (await file.exists()) {
      try {
        final text = (await file.readAsString()).trim();
        final seed = hexToBytes(text);
        if (seed != null && seed.length == 32) return await fromSeed(seed);
      } on FileSystemException {
        // fall through to regenerate
      }
      try {
        await file.rename('$path.invalid');
      } on FileSystemException {
        // keep going; worst case we overwrite
      }
    }
    final id = await generate();
    final seed = await id._keyPair.extractPrivateKeyBytes();
    await file.parent.create(recursive: true);
    await file.writeAsString(bytesToHex(Uint8List.fromList(seed)), flush: true);
    return id;
  }

  /// The {"t":"id"} proof for one session, bound to its channel binding.
  Future<Map<String, Object?>> proof(Uint8List channelBinding) async {
    final sig = await _ed25519.sign(_proofMessage(channelBinding, publicKey),
        keyPair: _keyPair);
    return {
      't': 'id',
      'v': 1,
      'key': publicKeyHex,
      'sig': bytesToHex(Uint8List.fromList(sig.bytes)),
    };
  }
}

/// Checks a peer's {"t":"id"} message against this session's binding; the
/// proven key (hex), or null if the message is malformed or the proof fails.
Future<String?> verifyProof(
    Map<String, Object?> message, Uint8List channelBinding) async {
  final keyHex = message['key'];
  final sigHex = message['sig'];
  if (keyHex is! String || sigHex is! String) return null;
  final key = hexToBytes(keyHex.toLowerCase());
  final sig = hexToBytes(sigHex.toLowerCase());
  if (key == null || key.length != 32 || sig == null || sig.length != 64) {
    return null;
  }
  final ok = await _ed25519.verify(
    _proofMessage(channelBinding, key),
    signature: Signature(sig,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
  );
  return ok ? bytesToHex(key) : null;
}

/// The first 16 bytes of SHA-256(public key), as 8 groups of 4 uppercase hex
/// digits: what people compare between devices.
String fingerprintOf(Uint8List publicKey) {
  final digest = crypto.sha256.convert(publicKey).bytes.sublist(0, 16);
  final hex = bytesToHex(Uint8List.fromList(digest)).toUpperCase();
  final groups = <String>[];
  for (var i = 0; i < hex.length; i += 4) {
    groups.add(hex.substring(i, i + 4));
  }
  return groups.join(' ');
}

String fingerprintOfHex(String keyHex) {
  final key = hexToBytes(keyHex.toLowerCase());
  return key == null ? '' : fingerprintOf(key);
}
