import 'dart:ui';
import 'package:flame/components.dart';
import '../core/constants.dart';
import '../core/spline.dart';
import '../core/spline_follower.dart';

/// A pedestrian that walks across a crossing spline.
class Pedestrian extends PositionComponent with SplineFollower {
  Pedestrian({
    required Spline crossingPath,
    required this.walkSpeed,
    required this.color,
  }) : super(
          size: Vector2(10, 10),
          anchor: Anchor.center,
          priority: kPedestrianPriority,
        ) {
    assignSpline(crossingPath);
  }

  final double walkSpeed;
  final Color color;

  bool get hasCrossed => hasReachedEnd;

  @override
  void update(double dt) {
    super.update(dt);
    advanceByDistance(walkSpeed * dt);
    position.setFrom(splinePosition);
    angle = splineAngle;
  }

  @override
  void render(Canvas canvas) {
    // Simple oval — body
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 10, height: 14),
      Paint()..color = color,
    );
    // Head
    canvas.drawCircle(const Offset(0, -9), 5, Paint()..color = color);
  }
}
