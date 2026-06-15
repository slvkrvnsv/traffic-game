import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/spline_follower.dart';
import '../core/utils.dart';
import 'car_definition.dart';
import 'car_painter.dart';

/// Abstract base for all cars — player and NPC.
///
/// Movement: spline-based with inertia.
/// Rendering: code-drawn via [CarPainter].
abstract class CarBase extends PositionComponent with SplineFollower {
  CarBase({
    required this.definition,
    super.priority,
  }) : super(
          size: Vector2(kCarLength, kCarWidth),
          anchor: Anchor.center,
        );

  final CarDefinition definition;

  // ---------------------------------------------------------------------------
  // Debug
  // ---------------------------------------------------------------------------

  /// Set by ViolationDetector each frame in debug builds; drives OBB outline colour.
  bool debugIsColliding = false;

  // ---------------------------------------------------------------------------
  // Motion
  // ---------------------------------------------------------------------------
  double speed = 0.0;
  double targetSpeed = 0.0;
  bool isBraking = false; // true = brake pedal held; false = coasting
  double brakeFraction = 1.0; // 0–1 analog brake strength; NPCs always 1.0

  double get rollingDrag => kPlayerRollingDrag;

  // ---------------------------------------------------------------------------
  // Visual state
  // ---------------------------------------------------------------------------
  bool _leftIndicator = false;
  bool _rightIndicator = false;
  double _indicatorTimer = 0.0;
  bool _indicatorBlinkState = false;

  double _wheelSteerAngle = 0.0;
  double _targetWheelAngle = 0.0;

  bool get leftIndicatorVisible => _leftIndicator && _indicatorBlinkState;
  bool get rightIndicatorVisible => _rightIndicator && _indicatorBlinkState;

  void setLeftIndicator(bool on) {
    if (on && !_leftIndicator) _restartBlink(); // off → on: clean first flash
    _leftIndicator = on;
    // Only clear the blink phase once *both* sides are off. These setters are
    // called every frame, so clearing on a single side's `false` would reset
    // the phase continuously and the active side would flicker for one frame.
    if (!_leftIndicator && !_rightIndicator) _indicatorBlinkState = false;
  }

  void setRightIndicator(bool on) {
    if (on && !_rightIndicator) _restartBlink();
    _rightIndicator = on;
    if (!_leftIndicator && !_rightIndicator) _indicatorBlinkState = false;
  }

  // ---------------------------------------------------------------------------
  // Update
  // ---------------------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);
    _updateMotion(dt);
    _updateIndicatorBlink(dt);
    _updateWheels(dt);
  }

  void _updateMotion(double dt) {
    // Inertia: lerp speed toward targetSpeed
    if (targetSpeed > speed) {
      speed = (speed + kPlayerAcceleration * dt).clamp(0.0, targetSpeed);
    } else if (targetSpeed < speed) {
      final decel = isBraking ? kPlayerBraking * brakeFraction : rollingDrag;
      speed = (speed - decel * dt).clamp(0.0, double.infinity);
    }

    if (speed <= 0.01) {
      speed = 0.0;
      return;
    }

    final overflow = advanceByDistance(speed * dt);
    // Subclass can handle overflow (e.g. snap to end)
    if (overflow > 0) onSplineEnd(overflow);

    // Update Flame position + rotation from spline
    final sp = splinePosition;
    if (spline != null) {
      position.setFrom(sp);
      angle = splineAngle;
    }
  }

  /// Begin a fresh blink cycle lit, so signalling always starts with a full
  /// on-phase rather than catching the middle of the running cycle.
  void _restartBlink() {
    _indicatorBlinkState = true;
    _indicatorTimer = 0.0;
  }

  void _updateIndicatorBlink(double dt) {
    if (!_leftIndicator && !_rightIndicator) return;
    _indicatorTimer += dt;
    if (_indicatorTimer >= kIndicatorBlinkPeriod) {
      _indicatorTimer -= kIndicatorBlinkPeriod;
      _indicatorBlinkState = !_indicatorBlinkState;
    }
  }

  void _updateWheels(double dt) {
    // Steer wheels toward tangent angle change (visual only)
    if (spline != null && speed > 5) {
      final t = currentT;
      final tAhead = (t + 0.02).clamp(0.0, 1.0);
      final angleNow = spline!.angleAt(t);
      final angleAhead = spline!.angleAt(tAhead);
      // Shortest-path difference — a raw subtraction jumps ~2π when the heading
      // crosses the ±π seam (cars travelling west), snapping the wheels to lock.
      _targetWheelAngle = normaliseAngle(angleAhead - angleNow).clamp(-0.6, 0.6);
    } else {
      _targetWheelAngle = 0.0;
    }
    _wheelSteerAngle = lerp(_wheelSteerAngle, _targetWheelAngle, 8 * dt);
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  @override
  void render(Canvas canvas) {
    // Flame's render origin (0,0) is the component's top-left corner.
    // Translate to the anchor (center) so CarPainter draws centred on
    // the car's world position.
    canvas.translate(size.x / 2, size.y / 2);
    CarPainter.paint(
      canvas: canvas,
      def: definition,
      leftIndicatorOn: leftIndicatorVisible,
      rightIndicatorOn: rightIndicatorVisible,
      wheelSteerAngle: _wheelSteerAngle,
    );
    if (kDebugMode) _debugRenderObb(canvas);
  }

  void _debugRenderObb(Canvas canvas) {
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: kCarLength, height: kCarWidth),
      Paint()
        ..color = debugIsColliding
            ? const Color(0xEEFF2222)
            : const Color(0x8800FF44)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  // ---------------------------------------------------------------------------
  // Hooks for subclasses
  // ---------------------------------------------------------------------------

  /// Called when the car reaches the end of its current spline.
  void onSplineEnd(double overflow) {}
}
