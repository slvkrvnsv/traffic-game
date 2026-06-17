import 'dart:ui';

/// MUTCD-style yellow diamond warning signs, drawn directly on the road canvas.
///
/// One painter for every sign — pass which [RoadSign] to draw. The diamond,
/// border and post are shared; only the inner symbol differs. Add a sign by
/// adding an enum value and a branch in [_drawSymbol].
enum RoadSign {
  /// W4-2 "Right Lane Ends" — the outer lane tapering into the inner one.
  laneEndsRight,

  /// "Added Lane (right)" — the mirror: a lane opening up on the right.
  laneAddedRight,
}

class RoadSigns {
  RoadSigns._();

  static const _yellow = Color(0xFFF9C300);
  static const _black = Color(0xFF111111);
  static const _postColor = Color(0xFF9E9E9E);

  /// Draw [sign] centred at [center] with diamond half-diagonal [r].
  static void draw(Canvas canvas, RoadSign sign, Offset center, {double r = 70}) {
    final sx = center.dx, sy = center.dy;

    // Post.
    canvas.drawRect(
      Rect.fromLTRB(sx - 4, sy + r, sx + 4, sy + r + 90),
      Paint()..color = _postColor,
    );

    // Diamond: yellow fill + black border.
    final diamond = Path()
      ..moveTo(sx, sy - r)
      ..lineTo(sx + r, sy)
      ..lineTo(sx, sy + r)
      ..lineTo(sx - r, sy)
      ..close();
    canvas.drawPath(diamond, Paint()..color = _yellow);
    canvas.drawPath(
      diamond,
      Paint()
        ..color = _black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );

    _drawSymbol(canvas, sign, sx, sy, r);
  }

  /// The lane-transition symbol. Authored for the *narrowing* case (the taper
  /// point at the top); the *widening* case is its vertical mirror ([fy] = -1),
  /// so a driver reads "a lane opens on the right" instead of "ends".
  static void _drawSymbol(
      Canvas canvas, RoadSign sign, double sx, double sy, double s) {
    final black = Paint()
      ..color = _black
      ..style = PaintingStyle.fill;
    final fy = sign == RoadSign.laneAddedRight ? -1.0 : 1.0;

    // Left bar — the through lane that continues straight (full height,
    // symmetric in y, so unaffected by the mirror).
    canvas.drawRect(
      Rect.fromLTRB(sx - 0.34 * s, sy - 0.46 * s, sx - 0.18 * s, sy + 0.46 * s),
      black,
    );

    // Right bar — the transitioning lane: a vertical run on the [fy] side that
    // bends in toward the through lane at the other end.
    canvas.drawPath(
      Path()
        ..moveTo(sx + 0.18 * s, sy + fy * 0.46 * s)
        ..lineTo(sx + 0.34 * s, sy + fy * 0.46 * s)
        ..lineTo(sx + 0.34 * s, sy + fy * -0.04 * s)
        ..lineTo(sx + 0.02 * s, sy + fy * -0.46 * s)
        ..lineTo(sx - 0.10 * s, sy + fy * -0.46 * s)
        ..lineTo(sx + 0.18 * s, sy + fy * -0.02 * s)
        ..close(),
      black,
    );

    // Dashed lane line between the two bars, on the wide ([fy]) half.
    for (final k in const [0.14, 0.28, 0.42]) {
      final cy = sy + fy * k * s;
      canvas.drawRect(
        Rect.fromLTRB(sx - 0.03 * s, cy - 0.05 * s, sx + 0.03 * s, cy + 0.05 * s),
        black,
      );
    }
  }
}
