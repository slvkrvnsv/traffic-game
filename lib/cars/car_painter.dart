import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../core/constants.dart';
import 'car_definition.dart';

/// Stateless car drawing helper.
/// All drawing is in local space centred on (0, 0), facing right (+x).
/// The caller is responsible for applying the world transform.
class CarPainter {
  /// Reused glow brush for the headlight courtesy flash — the `MaskFilter.blur`
  /// is constant and costly to rebuild, so it's allocated once; callers update
  /// only its colour/alpha.
  static final Paint _glowPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

  static void paint({
    required Canvas canvas,
    required CarDefinition def,
    required bool leftIndicatorOn,
    required bool rightIndicatorOn,
    required double wheelSteerAngle, // radians, front wheels only
    bool headlightFlash = false, // courtesy flash (waving a car on)
    double opacity = 1.0,
  }) {
    final bodyW = kCarWidth * def.widthRatio;
    final bodyL = kCarLength * def.lengthRatio;

    final bodyPaint = Paint()
      ..color = def.bodyColor.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;

    final roofPaint = Paint()
      ..color = def.roofColor.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;

    // --- Body ---
    final bodyRect =
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: bodyL, height: bodyW), const Radius.circular(6));
    canvas.drawRRect(bodyRect, bodyPaint);

    // --- Roof (smaller, centred slightly toward rear) ---
    final roofRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: const Offset(-4, 0), width: bodyL * 0.5, height: bodyW * 0.65),
      const Radius.circular(4),
    );
    canvas.drawRRect(roofRect, roofPaint);

    // --- Headlights (front = +x) ---
    // When flashing (courtesy "go ahead" at a stop), the lamps blaze bright
    // white with a soft glow; otherwise a dim warm running-light.
    if (headlightFlash) {
      // Reuse one Paint/MaskFilter (the blur is the costly part and is
      // constant); only the alpha tracks the fade.
      _glowPaint.color = const Color(0xFFFFFFFF).withValues(alpha: 0.5 * opacity);
      _drawLight(canvas, Offset(bodyL / 2 - 3, -bodyW / 2 + 5), 12, 8, const Color(0xFFFFFFFF));
      _drawLight(canvas, Offset(bodyL / 2 - 3, bodyW / 2 - 5), 12, 8, const Color(0xFFFFFFFF));
      canvas.drawCircle(Offset(bodyL / 2 + 2, -bodyW / 2 + 5), 7, _glowPaint);
      canvas.drawCircle(Offset(bodyL / 2 + 2, bodyW / 2 - 5), 7, _glowPaint);
    } else {
      _drawLight(canvas, Offset(bodyL / 2 - 4, -bodyW / 2 + 5), 5, 3, const Color(0xFFFFF9C4));
      _drawLight(canvas, Offset(bodyL / 2 - 4, bodyW / 2 - 5), 5, 3, const Color(0xFFFFF9C4));
    }

    // --- Taillights (rear = -x) ---
    _drawLight(canvas, Offset(-bodyL / 2 + 4, -bodyW / 2 + 5), 5, 3, const Color(0xFFEF9A9A));
    _drawLight(canvas, Offset(-bodyL / 2 + 4, bodyW / 2 - 5), 5, 3, const Color(0xFFEF9A9A));

    // --- Wheels ---
    _drawWheels(canvas, bodyL, bodyW, wheelSteerAngle, opacity);

    // --- Indicators (blinking 9-point stars, exam-ticket style) ---
    // Drawn last so the flashing star sits on top of body and wheels. The
    // *_On flags are already blink-gated upstream, so a star = the "on" phase.
    // Local space faces +x; -y is the car's left side, +y its right.
    final lx = bodyL / 2 - 2; // front axle of lights
    final rx = -bodyL / 2 + 2; // rear
    if (leftIndicatorOn) {
      _drawIndicatorStar(canvas, Offset(lx, -bodyW / 2), opacity);
      _drawIndicatorStar(canvas, Offset(rx, -bodyW / 2), opacity);
    }
    if (rightIndicatorOn) {
      _drawIndicatorStar(canvas, Offset(lx, bodyW / 2), opacity);
      _drawIndicatorStar(canvas, Offset(rx, bodyW / 2), opacity);
    }
  }

  /// A bright amber 9-pointed star at a car corner — the classic blinking
  /// turn-signal glyph from the old exam tickets. A soft glow and a hot white
  /// core make it read clearly even at the game's zoom-out.
  static void _drawIndicatorStar(Canvas canvas, Offset center, double opacity) {
    const outerR = 7.0;
    const innerR = 2.9;
    const color = Color(0xFFFFC400);

    // Soft glow behind the star.
    canvas.drawCircle(
      center,
      outerR * 1.25,
      Paint()
        ..color = color.withValues(alpha: 0.35 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );

    // The 9-point star.
    canvas.drawPath(
      _starPath(center, outerR, innerR, 9),
      Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.fill,
    );

    // Hot core.
    canvas.drawCircle(
      center,
      innerR * 0.7,
      Paint()..color = const Color(0xFFFFFDE7).withValues(alpha: opacity),
    );
  }

  /// Builds an [n]-pointed star path centred on [c], alternating between
  /// [outer] and [inner] radii.
  static Path _starPath(Offset c, double outer, double inner, int n) {
    final path = Path();
    final verts = n * 2;
    for (int i = 0; i < verts; i++) {
      final r = i.isEven ? outer : inner;
      final a = -math.pi / 2 + i * math.pi / n; // step = π/n between vertices
      final p = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  static void _drawLight(Canvas canvas, Offset center, double w, double h, Color color) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: w, height: h),
        const Radius.circular(1),
      ),
      Paint()..color = color,
    );
  }

  static void _drawWheels(Canvas canvas, double bodyL, double bodyW, double steerAngle, double opacity) {
    final wheelPaint = Paint()
      ..color = const Color(0xFF212121).withValues(alpha: opacity)
      ..style = PaintingStyle.fill;

    // Wheel positions in local car space
    final offsets = [
      Offset(bodyL * 0.32, -bodyW / 2 - 2),  // front-left
      Offset(bodyL * 0.32, bodyW / 2 + 2),   // front-right
      Offset(-bodyL * 0.28, -bodyW / 2 - 2), // rear-left
      Offset(-bodyL * 0.28, bodyW / 2 + 2),  // rear-right
    ];

    for (int i = 0; i < 4; i++) {
      final isFront = i < 2;
      final angle = isFront ? steerAngle : 0.0;
      canvas.save();
      canvas.translate(offsets[i].dx, offsets[i].dy);
      canvas.rotate(angle);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: kWheelLength, height: kWheelWidth),
          const Radius.circular(2),
        ),
        wheelPaint,
      );
      canvas.restore();
    }
  }
}
