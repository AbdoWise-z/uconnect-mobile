// Exercises the FFI binding against a host build of uconnect_c; skips when
// UCONNECT_C_LIBRARY is not set.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/uconnect/uconnect.dart';

void main() {
  if (Platform.environment['UCONNECT_C_LIBRARY'] == null) {
    test('creds FFI (skipped: set UCONNECT_C_LIBRARY)', () {},
        skip: 'native library not configured');
    return;
  }

  test('generated keyed creds round-trip through their URI', () {
    final creds = TopicCreds.generate();
    expect(creds.keyed, isTrue);
    expect(creds.id.length, 16);
    expect(creds.key!.length, 32);
    final uri = creds.toUri();
    expect(uri, startsWith('uconn://'));
    expect(uri, contains('#'));
    final back = TopicCreds.parse(uri)!;
    expect(back.idHex, creds.idHex);
    expect(back.key, creds.key);
  });

  test('open creds have no key and no fragment', () {
    final creds = TopicCreds.generate(keyed: false);
    expect(creds.keyed, isFalse);
    final uri = creds.toUri();
    expect(uri, isNot(contains('#')));
    expect(TopicCreds.parse(uri)!.keyed, isFalse);
  });

  test('malformed URIs parse to null', () {
    expect(TopicCreds.parse(''), isNull);
    expect(TopicCreds.parse('uconn://zzzz'), isNull);
    expect(TopicCreds.parse('http://example.com'), isNull);
    expect(TopicCreds.parse('uconn://abcd#12'), isNull);
  });

  test('hex helpers round-trip', () {
    expect(bytesToHex(hexToBytes('00ff10ab')!), '00ff10ab');
    expect(hexToBytes('xyz'), isNull);
    expect(hexToBytes('abc'), isNull); // odd length
  });
}
