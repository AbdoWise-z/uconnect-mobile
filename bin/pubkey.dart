// Prints an identity's public key hex and fingerprint from its 32-byte seed
// (hex). Used by the screen-demo setup to pre-trust the phone on the desktop.
import 'dart:io';
import 'package:uconnect_mobile/core/identity.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

Future<void> main(List<String> args) async {
  final seed = hexToBytes(args.first.trim());
  if (seed == null || seed.length != 32) {
    stderr.writeln('need a 64-hex-char seed');
    exit(2);
  }
  final id = await Identity.fromSeed(seed);
  // ignore: avoid_print
  print('${id.publicKeyHex} ${id.fingerprint}');
}
