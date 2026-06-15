import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../input/speed_state.dart';

/// Top-right HUD speedometer — analog arc + digital readout.
/// Designed to sit inside the GameScreen Stack.
class SpeedometerHud extends StatelessWidget {
  const SpeedometerHud({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 12, right: 16),
          child: ValueListenableBuilder<double>(
            valueListenable: SpeedState.instance.speedKmh,
            builder: (context, kmh, child) => CustomPaint(
              size: const Size(88, 88),
              painter: _SpeedometerPainter(kmh: kmh),
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeedometerPainter extends CustomPainter {
  const _SpeedometerPainter({required this.kmh});

  final double kmh;

  /// Gauge covers 0–160 km/h; player max is 150 km/h so the needle never pins.
  static const double _maxKmh = 160;

  /// Arc: starts at ~7 o'clock, sweeps 270° clockwise to ~5 o'clock.
  static const double _startRad = 3 * math.pi / 4; // 135°
  static const double _sweepRad = 3 * math.pi / 2; // 270°

  /// Major tick values shown on the gauge.
  static const List<int> _majorTicks = [0, 40, 80, 120, 160];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);
    final outerR = cx - 2;
    final arcR = cx - 10;

    final fraction = (kmh / _maxKmh).clamp(0.0, 1.0);

    // ── Background disc ──────────────────────────────────────────────────────
    canvas.drawCircle(
      center,
      outerR,
      Paint()..color = const Color(0xE6111111),
    );

    // ── Track (empty arc) ────────────────────────────────────────────────────
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: arcR),
      _startRad,
      _sweepRad,
      false,
      Paint()
        ..color = const Color(0xFF2A2A2A)
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // ── Speed arc (colored fill) ─────────────────────────────────────────────
    if (fraction > 0.005) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: arcR),
        _startRad,
        _sweepRad * fraction,
        false,
        Paint()
          ..color = _arcColor(fraction)
          ..strokeWidth = 8
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── Major tick marks ─────────────────────────────────────────────────────
    final tickInnerR = arcR - 7;
    final tickOuterR = arcR + 1;
    final tickPaint = Paint()
      ..color = const Color(0xFF555555)
      ..strokeWidth = 1.5;

    for (final v in _majorTicks) {
      final t = v / _maxKmh;
      final angle = _startRad + _sweepRad * t;
      final inner = center + Offset(math.cos(angle), math.sin(angle)) * tickInnerR;
      final outer = center + Offset(math.cos(angle), math.sin(angle)) * tickOuterR;
      canvas.drawLine(inner, outer, tickPaint);
    }

    // ── Digital speed readout ────────────────────────────────────────────────
    final speedStr = kmh.round().toString();
    final speedStyle = TextStyle(
      color: Colors.white,
      fontSize: speedStr.length >= 3 ? 22.0 : 26.0,
      fontWeight: FontWeight.bold,
      height: 1,
    );
    final speedSpan = TextSpan(text: speedStr, style: speedStyle);
    final speedPainter = TextPainter(
      text: speedSpan,
      textDirection: TextDirection.ltr,
    )..layout();
    speedPainter.paint(
      canvas,
      center + Offset(-speedPainter.width / 2, -speedPainter.height / 2 - 4),
    );

    // ── "km/h" label ─────────────────────────────────────────────────────────
    const unitStyle = TextStyle(
      color: Color(0xFF777777),
      fontSize: 9,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    );
    final unitPainter = TextPainter(
      text: const TextSpan(text: 'km/h', style: unitStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    unitPainter.paint(
      canvas,
      center + Offset(-unitPainter.width / 2, 10),
    );
  }

  /// Green → orange → red as speed increases.
  Color _arcColor(double fraction) {
    if (fraction < 0.5) {
      return Color.lerp(
        const Color(0xFF4CAF50),
        const Color(0xFFFF9800),
        fraction * 2,
      )!;
    }
    return Color.lerp(
      const Color(0xFFFF9800),
      const Color(0xFFF44336),
      (fraction - 0.5) * 2,
    )!;
  }

  @override
  bool shouldRepaint(_SpeedometerPainter old) => old.kmh != kmh;
}
