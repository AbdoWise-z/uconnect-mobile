// The uConnect logo, drawn as vectors from packaging/icons/uconnect.svg in
// uconnect-desktop: a "u" whose arm tips are two connected devices, before a
// blue C that echoes it across the diagonal, on a white rounded tile.

import 'package:flutter/material.dart';

class UcLogo extends StatelessWidget {
  const UcLogo({this.size = 64, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _LogoPainter()),
      );
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // The SVG's viewBox is -51.2 -51.2 1126.4 1126.4 around a 1024 tile.
    final s = size.width / 1126.4;
    canvas.scale(s);
    canvas.translate(51.2, 51.2);

    const tile = Rect.fromLTWH(0, 0, 1024, 1024);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(tile, const Radius.circular(228)));
    canvas.drawRect(tile, Paint()..color = Colors.white);
    final band = Path()
      ..moveTo(907.7, 508.8)
      ..lineTo(514.7, 115.8)
      ..lineTo(115.8, 514.7)
      ..lineTo(508.8, 907.7)
      ..lineTo(590.7, 825.7)
      ..lineTo(278.1, 513.1)
      ..lineTo(513.1, 278.1)
      ..lineTo(825.7, 590.7)
      ..close();
    canvas.drawPath(
        band,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF5B9BFF), Color(0xFF2F5FD8)],
          ).createShader(band.getBounds()));
    canvas.restore();

    canvas.translate(512, 512);
    canvas.scale(0.84);
    canvas.translate(-512, -512);
    final ink = Paint()
      ..color = const Color(0xFF111111)
      ..style = PaintingStyle.stroke;
    final u = Path()
      ..moveTo(352, 426)
      ..lineTo(352, 600)
      ..arcToPoint(const Offset(672, 600),
          radius: const Radius.circular(160), clockwise: false)
      ..lineTo(672, 426);
    canvas.drawPath(u, ink..strokeWidth = 112);
    ink.strokeWidth = 52;
    canvas.drawCircle(const Offset(352, 360), 66, ink);
    canvas.drawCircle(const Offset(672, 360), 66, ink);
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => false;
}
