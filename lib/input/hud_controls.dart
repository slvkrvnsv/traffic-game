import 'package:flutter/material.dart';
import 'input_state.dart';

/// Flutter overlay: a floating vertical joystick.
///
/// It materialises under the finger on touch-down:
///   • tap & hold (neutral)  → car accelerates up to the cruise speed (50 km/h)
///   • swipe up              → throttle ramps from cruise toward max
///   • swipe down            → brakes, harder the further you push
///   • release               → inputs clear; the car coasts on inertia (rolling drag)
///
/// Horizontal movement is ignored — only the vertical offset from the touch
/// origin matters. Gas/brake are written to [InputState]; PlayerCar reads them.
class HudControls extends StatefulWidget {
  const HudControls({super.key});

  @override
  State<HudControls> createState() => _HudControlsState();
}

class _HudControlsState extends State<HudControls> {
  /// Pixels of vertical travel from the origin for a full up/down command.
  static const double _maxTravel = 87.0;

  /// Throttle held at the neutral (hold) position: 50 of 150 km/h.
  static const double _cruiseFraction = 50.0 / 150.0;

  /// Dead zone around neutral so a steady hold stays at cruise without jitter.
  static const double _deadZone = 10.0;

  Offset? _origin; // where the finger first touched down (local coords)
  double _dy = 0.0; // signed vertical offset from origin, up = positive

  void _onStart(Offset p) {
    _origin = p;
    _setDy(0.0);
  }

  void _onUpdate(Offset p) {
    _setDy(_origin!.dy - p.dy); // screen y grows downward → invert
  }

  void _setDy(double rawDy) {
    setState(() => _dy = rawDy.clamp(-_maxTravel, _maxTravel));

    final input = InputState.instance;
    if (_dy.abs() <= _deadZone) {
      // Neutral hold → cruise.
      input.setBrakeLevel(0.0);
      input.setGasLevel(_cruiseFraction);
      return;
    }

    final norm = (_dy.abs() - _deadZone) / (_maxTravel - _deadZone);
    // Progressive response: gentle near neutral, ramps hard toward the ends.
    // Full swipe-down is an emergency stop; full swipe-up is max throttle.
    final eased = norm * norm;
    if (_dy > 0) {
      // Up zone: cruise → full throttle.
      input.setBrakeLevel(0.0);
      input.setGasLevel(_cruiseFraction + (1.0 - _cruiseFraction) * eased);
    } else {
      // Down zone: proportional braking.
      input.setGasLevel(0.0);
      input.setBrakeLevel(eased);
    }
  }

  void _onEnd() {
    setState(() {
      _origin = null;
      _dy = 0.0;
    });
    InputState.instance.setGasLevel(0.0);
    InputState.instance.setBrakeLevel(0.0);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanDown: (d) => _onStart(d.localPosition),
        onPanStart: (d) => _onStart(d.localPosition),
        onPanUpdate: (d) => _onUpdate(d.localPosition),
        onPanEnd: (_) => _onEnd(),
        onPanCancel: _onEnd,
        child: _origin == null
            ? const SizedBox.expand()
            : CustomPaint(
                size: Size.infinite,
                painter: _JoystickPainter(
                  origin: _origin!,
                  dy: _dy,
                  maxTravel: _maxTravel,
                  deadZone: _deadZone,
                ),
              ),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  const _JoystickPainter({
    required this.origin,
    required this.dy,
    required this.maxTravel,
    required this.deadZone,
  });

  final Offset origin;
  final double dy; // signed, up = positive
  final double maxTravel;
  final double deadZone;

  static const double _trackHalfWidth = 36.0;
  static const double _knobRadius = 34.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = origin.dx;
    final cy = origin.dy;

    // Track: a rounded capsule spanning the full travel range.
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        cx - _trackHalfWidth,
        cy - maxTravel - _knobRadius,
        cx + _trackHalfWidth,
        cy + maxTravel + _knobRadius,
      ),
      const Radius.circular(_trackHalfWidth),
    );
    canvas.drawRRect(trackRect, Paint()..color = const Color(0x22FFFFFF));

    // Fill from neutral toward the knob, tinted by zone.
    if (dy.abs() > deadZone) {
      final knobY = cy - dy;
      canvas.save();
      canvas.clipRRect(trackRect);
      final fillRect = dy > 0
          ? Rect.fromLTRB(cx - _trackHalfWidth, knobY, cx + _trackHalfWidth, cy)
          : Rect.fromLTRB(cx - _trackHalfWidth, cy, cx + _trackHalfWidth, knobY);
      canvas.drawRect(fillRect, Paint()..color = _zoneColor());
      canvas.restore();
    }

    // Neutral marker.
    canvas.drawLine(
      Offset(cx - _trackHalfWidth, cy),
      Offset(cx + _trackHalfWidth, cy),
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..strokeWidth = 1.5,
    );

    // Track outline.
    canvas.drawRRect(
      trackRect,
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Knob.
    final knobCenter = Offset(cx, cy - dy);
    canvas.drawCircle(knobCenter, _knobRadius, Paint()..color = _zoneColor());
    canvas.drawCircle(
      knobCenter,
      _knobRadius,
      Paint()
        ..color = const Color(0xCCFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Direction hint on the knob.
    final icon = dy.abs() <= deadZone
        ? Icons.drag_handle_rounded
        : (dy > 0 ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded);
    _paintIcon(canvas, icon, knobCenter);
  }

  Color _zoneColor() {
    if (dy.abs() <= deadZone) return const Color(0xAA4CAF50);
    final linear = (dy.abs() - deadZone) / (maxTravel - deadZone);
    final norm = linear * linear; // match the progressive force curve
    if (dy > 0) {
      // Green → amber → red as throttle climbs.
      return norm < 0.5
          ? Color.lerp(const Color(0xAA4CAF50), const Color(0xAAFF9800), norm * 2)!
          : Color.lerp(const Color(0xAAFF9800), const Color(0xAAF44336), (norm - 0.5) * 2)!;
    }
    // Braking: orange → deep red.
    return Color.lerp(const Color(0xAAFF7043), const Color(0xAAEF1010), norm)!;
  }

  void _paintIcon(Canvas canvas, IconData icon, Offset center) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 34,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_JoystickPainter old) =>
      old.origin != origin || old.dy != dy;
}
