// The E2E host (tool/e2e_host.dart) run on a device: a phone that serves a
// share and shares a "screen" and "camera", so another device can browse and
// watch it over whatever network the phone is on.
//
//   flutter test integration_test/device_host_test.dart -d <device> //     --no-uninstall //     --dart-define=E2E_SERVER=host:port --dart-define=E2E_TOPIC=uconn://... //     --dart-define=E2E_SHARE=@temp --dart-define=E2E_RELAY=0 //     --dart-define=E2E_CAPTURE=screen --dart-define=E2E_SERVE_SECONDS=240
//
// It prints "E2E_HOST READY <id>" once published and serves for
// E2E_SERVE_SECONDS. Keep --no-uninstall: without it `flutter test` removes
// the app, and its data, from the device afterwards.
//
// With E2E_CAPTURE=screen the phone's real screen goes out through its real
// encoder, and this test keeps a moving picture on it: a screen capture only
// sends frames when the picture changes. Without it, pass a recorded stream as
// E2E_H264=http://127.0.0.1:<port>/sample.h264 (on Android the computer's own
// port, through `adb reverse tcp:<port> tcp:<port>`).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../tool/e2e_host.dart' as host;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames keep coming while the host serves, as in the running app.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  if (host.server.isEmpty || host.topic.isEmpty) {
    test('device host (skipped: needs E2E_SERVER and E2E_TOPIC)', () {},
        skip: 'E2E_SERVER / E2E_TOPIC not set');
    return;
  }

  testWidgets('serve from this device', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Colors.black, body: _MovingPicture()),
    ));
    await tester.runAsync(host.serveHost);
  }, timeout: Timeout.none);
}

/// Bars sweeping across the screen and a running clock: something that
/// changes on every frame.
class _MovingPicture extends StatefulWidget {
  const _MovingPicture();

  @override
  State<_MovingPicture> createState() => _MovingPictureState();
}

class _MovingPictureState extends State<_MovingPicture>
    with SingleTickerProviderStateMixin {
  late final _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))
        ..repeat();
  final _since = Stopwatch()..start();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spin,
      builder: (context, _) => Stack(fit: StackFit.expand, children: [
        CustomPaint(painter: _Bars(_spin.value)),
        Center(
          child: Text(
            (_since.elapsedMilliseconds / 1000).toStringAsFixed(2),
            style: const TextStyle(
                color: Colors.white, fontSize: 72, fontWeight: FontWeight.w700),
          ),
        ),
      ]),
    );
  }
}

class _Bars extends CustomPainter {
  _Bars(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    const colors = [
      Color(0xFFE6E6E6), Color(0xFFE6E61A), Color(0xFF1AE6E6), Color(0xFF1ACC1A),
      Color(0xFFE61AE6), Color(0xFFE61A1A), Color(0xFF1A1AE6), Color(0xFF1A1A1A),
    ];
    final bar = size.width / colors.length;
    final shift = t * size.width;
    for (var i = -colors.length; i < colors.length * 2; i++) {
      canvas.drawRect(
          Rect.fromLTWH(i * bar + shift % (bar * colors.length), 0, bar + 1, size.height),
          Paint()..color = colors[i % colors.length]);
    }
    final side = size.width / 5;
    canvas.drawRect(
        Rect.fromLTWH(
            (size.width - side) * (0.5 + 0.5 * math.sin(t * 2 * math.pi)),
            size.height * 0.25,
            side,
            side),
        Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_Bars old) => old.t != t;
}
