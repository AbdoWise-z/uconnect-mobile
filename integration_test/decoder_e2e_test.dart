// On-device test of the native H.264 decoder behind the "uconnect/screen"
// channel (ScreenDecoder.kt, ScreenDecoder.swift): feeds it a real stream at
// its own pace and checks that pictures come out, at the right size, into a
// Flutter texture. Driven by scripts/e2e-ios.sh, which makes the stream with
// scripts/h264-sample.swift, serves it over HTTP, and passes:
//
//   E2E_H264        URL of the stream (the device reaches the Mac's loopback)
//   E2E_H264_SIZE   its picture size, as WIDTHxHEIGHT
//   E2E_HOLD        seconds to rest on the last picture (for screenshots)

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const streamUrl = String.fromEnvironment('E2E_H264');
const streamSize = String.fromEnvironment('E2E_H264_SIZE', defaultValue: '640x360');
const hold = int.fromEnvironment('E2E_HOLD');
const fps = 30;

class Unit {
  Unit(this.keyframe, this.bytes);
  final bool keyframe;
  final Uint8List bytes;
}

/// The file format of scripts/h264-sample.swift.
List<Unit> parseUnits(Uint8List data) {
  final units = <Unit>[];
  final view = ByteData.sublistView(data);
  var at = 0;
  while (at + 5 <= data.length) {
    final length = view.getUint32(at);
    final keyframe = data[at + 4] == 1;
    at += 5;
    if (at + length > data.length) break;
    units.add(Unit(keyframe, Uint8List.sublistView(data, at, at + length)));
    at += length;
  }
  return units;
}

Future<Uint8List> fetch(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    if (response.statusCode != 200) {
      fail('GET $url answered ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (streamUrl.isEmpty) {
    test('decoder E2E (skipped: run through scripts/e2e-ios.sh)', () {},
        skip: 'E2E_H264 not set');
    return;
  }

  for (final bufferMs in [0, 150]) {
    testWidgets('decodes a stream into a texture (buffer $bufferMs ms)',
        (tester) async {
      final wanted = streamSize.split('x').map(int.parse).toList();
      final units = parseUnits(await fetch(streamUrl));
      expect(units.length, greaterThan(30), reason: 'a usable stream');
      expect(units.first.keyframe, isTrue);

      const channel = MethodChannel('uconnect/screen');
      final sizes = <Size>[];
      final errors = <String>[];
      channel.setMethodCallHandler((call) async {
        if (call.method == 'size') {
          final a = call.arguments as Map;
          sizes.add(Size((a['width'] as num).toDouble(),
              (a['height'] as num).toDouble()));
        } else if (call.method == 'error') {
          errors.add('${call.arguments}');
        }
        return null;
      });
      addTearDown(() async {
        await channel.invokeMethod<void>('dispose');
        channel.setMethodCallHandler(null);
      });

      final created = await channel
          .invokeMapMethod<String, Object?>('create', {'bufferMs': bufferMs});
      final textureId = created?['textureId'] as int?;
      expect(textureId, isNotNull);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: AspectRatio(
              aspectRatio: wanted[0] / wanted[1],
              child: Texture(textureId: textureId!),
            ),
          ),
        ),
      ));

      // Fed like a live stream over a steady path: each unit stamped with
      // the time it is handed over, about a frame apart.
      for (var i = 0; i < units.length; i++) {
        await channel.invokeMethod<void>('decode', {
          'bytes': units[i].bytes,
          'keyframe': units[i].keyframe,
          'ptsUs': DateTime.now().microsecondsSinceEpoch,
        });
        await tester.pump(const Duration(milliseconds: 1000 ~/ fps));
      }
      // The last pictures: decoded, and shown after the buffer.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final stats =
          await channel.invokeMapMethod<String, Object?>('stats') ?? const {};
      // ignore: avoid_print
      print('E2E_DECODER buffer=$bufferMs units=${units.length} '
          'sizes=$sizes stats=$stats errors=$errors');
      expect(errors, isEmpty);
      expect(sizes, isNotEmpty, reason: 'the decoder reported a picture size');
      expect(sizes.last, Size(wanted[0].toDouble(), wanted[1].toDouble()));
      expect(stats['rendered'], units.length,
          reason: 'every access unit came out as a picture');
      expect(stats['bufferMs'], bufferMs);
      expect(stats['late'], lessThanOrEqualTo(units.length ~/ 10),
          reason: 'a steady stream is shown on time');

      for (var i = 0; i < hold * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
