import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/identity.dart';

void main() {
  test('a proof verifies against its binding and fails against another', () async {
    final id = await Identity.generate();
    final binding = Uint8List.fromList(List.generate(32, (i) => i));
    final proof = await id.proof(binding);
    expect(proof['t'], 'id');
    expect((proof['key'] as String).length, 64);
    expect((proof['sig'] as String).length, 128);

    expect(await verifyProof(proof, binding), id.publicKeyHex);

    final otherBinding = Uint8List.fromList(List.generate(32, (i) => i + 1));
    expect(await verifyProof(proof, otherBinding), isNull);

    final tampered = Map<String, Object?>.from(proof);
    final sig = tampered['sig'] as String;
    tampered['sig'] =
        '${sig.substring(0, 126)}${sig.endsWith('00') ? '01' : '00'}';
    expect(await verifyProof(tampered, binding), isNull);
  });

  test('uppercase hex in a proof is accepted', () async {
    final id = await Identity.generate();
    final binding = Uint8List(32);
    final proof = await id.proof(binding);
    proof['key'] = (proof['key'] as String).toUpperCase();
    proof['sig'] = (proof['sig'] as String).toUpperCase();
    expect(await verifyProof(proof, binding), id.publicKeyHex);
  });

  test('malformed proofs are rejected, not crashed on', () async {
    final binding = Uint8List(32);
    expect(await verifyProof({'t': 'id'}, binding), isNull);
    expect(await verifyProof({'t': 'id', 'key': 'zz', 'sig': 'zz'}, binding),
        isNull);
    expect(
        await verifyProof(
            {'t': 'id', 'key': 'ab', 'sig': 'cd' * 64}, binding),
        isNull);
  });

  test('fingerprint is 8 groups of 4 uppercase hex digits', () async {
    final id = await Identity.generate();
    final fp = id.fingerprint;
    expect(RegExp(r'^([0-9A-F]{4} ){7}[0-9A-F]{4}$').hasMatch(fp), isTrue,
        reason: fp);
    expect(fingerprintOfHex(id.publicKeyHex), fp);
  });

  test('loadOrCreate persists the identity and reloads the same key', () async {
    final dir = await Directory.systemTemp.createTemp('ucid');
    try {
      final path = '${dir.path}${Platform.pathSeparator}identity';
      final first = await Identity.loadOrCreate(path);
      final second = await Identity.loadOrCreate(path);
      expect(second.publicKeyHex, first.publicKeyHex);
      // A corrupt file is moved aside and a fresh identity made.
      await File(path).writeAsString('not hex at all');
      final third = await Identity.loadOrCreate(path);
      expect(third.publicKeyHex, isNot(first.publicKeyHex));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
