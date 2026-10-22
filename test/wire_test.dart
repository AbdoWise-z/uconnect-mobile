import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/wire.dart';

void main() {
  test('control messages round-trip as kind 1 compact JSON', () {
    final bytes = encodeControl({'t': 'hello', 'v': 1, 'name': 'Phone'});
    expect(bytes[0], MessageKind.control);
    final back = decodeControl(bytes);
    expect(back, isNotNull);
    expect(back!['t'], 'hello');
    expect(back['name'], 'Phone');
  });

  test('non-control and malformed messages decode to null', () {
    expect(decodeControl(Uint8List(0)), isNull);
    expect(decodeControl(Uint8List.fromList([2, 1, 2, 3])), isNull);
    expect(decodeControl(Uint8List.fromList([1, 0x7b])), isNull); // "{"
    expect(decodeControl(Uint8List.fromList([1, 0x34, 0x32])), isNull); // "42"
  });

  test('data frames carry a big-endian u32 id', () {
    final frame = encodeDataFrame(MessageKind.data, 0xA1B2C3D4, [9, 8, 7]);
    expect(frame.sublist(0, 5), [2, 0xA1, 0xB2, 0xC3, 0xD4]);
    final back = decodeDataFrame(frame)!;
    expect(back.kind, MessageKind.data);
    expect(back.id, 0xA1B2C3D4);
    expect(back.bytes, [9, 8, 7]);
  });

  test('unknown frame kinds decode to null', () {
    expect(decodeDataFrame(Uint8List.fromList([9, 0, 0, 0, 1, 42])), isNull);
    expect(decodeDataFrame(Uint8List.fromList([2, 0, 0])), isNull); // short
  });

  test('hello clamps the peer\'s claims and drops unknown services', () {
    final hello = Hello.fromJson({
      't': 'hello',
      'v': 1,
      'name': 'x' * 100,
      'os': 'y' * 50,
      'svc': ['storage', 'bogus', 'screen', 42],
    })!;
    expect(hello.name.length, 64);
    expect(hello.os.length, 32);
    expect(hello.services, ['storage', 'screen']);
  });
}
