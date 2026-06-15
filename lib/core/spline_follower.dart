import 'dart:math' as math;
import 'package:flame/components.dart';
import 'spline.dart';

/// Mixin for any component that follows a [Spline] at a given speed.
///
/// Splines are authored in tile-local coordinates; [worldOffset] and
/// [worldAngle] describe the owning tile's placement (translation + rotation
/// about the tile origin), so followers move correctly in the world without
/// creating a transformed copy of the spline.
mixin SplineFollower {
  Spline? _spline;
  double _distanceTravelled = 0.0;
  Vector2 _worldOffset = Vector2.zero();
  double _worldAngle = 0.0;
  double _cosA = 1.0;
  double _sinA = 0.0;

  Spline? get spline => _spline;

  /// Signed lateral offset (world units) applied perpendicular to the direction
  /// of travel, positive = right of travel. Used to slide a car off its lane
  /// centreline during a lane change while it keeps advancing along the new
  /// lane's spline; eased back to 0 once the manoeuvre completes.
  double lateralOffset = 0.0;

  double get currentT =>
      _spline == null ? 0.0 : _distanceTravelled / _spline!.totalLength;

  bool get hasReachedEnd => currentT >= 1.0;

  /// World-space position on the lane *centreline*, ignoring [lateralOffset].
  /// Used for seam matching so a lane-change lean doesn't bias which lane the
  /// player is handed to.
  Vector2 get splineCentrePosition {
    final local = _spline?.evaluate(currentT) ?? Vector2.zero();
    return Vector2(
      _worldOffset.x + local.x * _cosA - local.y * _sinA,
      _worldOffset.y + local.x * _sinA + local.y * _cosA,
    );
  }

  /// World-space position: the lane centreline plus any [lateralOffset]
  /// perpendicular to the travel direction.
  Vector2 get splinePosition {
    final base = splineCentrePosition;
    if (lateralOffset != 0.0) {
      final a = splineAngle;
      // Right-hand perpendicular of the travel direction (screen y-down).
      base.x += -math.sin(a) * lateralOffset;
      base.y += math.cos(a) * lateralOffset;
    }
    return base;
  }

  /// World-space angle at current progress.
  double get splineAngle => (_spline?.angleAt(currentT) ?? 0.0) + _worldAngle;

  // ---------------------------------------------------------------------------
  // Control
  // ---------------------------------------------------------------------------

  /// Assign a new spline, reset progress, and record the tile's placement
  /// ([worldOffset] translation + [worldAngle] rotation about the tile origin).
  void assignSpline(
    Spline spline, {
    double startDistance = 0.0,
    Vector2? worldOffset,
    double worldAngle = 0.0,
  }) {
    _spline = spline;
    _distanceTravelled = startDistance.clamp(0.0, spline.totalLength);
    _worldOffset = worldOffset?.clone() ?? Vector2.zero();
    _worldAngle = worldAngle;
    _cosA = math.cos(worldAngle);
    _sinA = math.sin(worldAngle);
  }

  /// Advance by [distance] world units. Returns overflow if end was reached.
  double advanceByDistance(double distance) {
    if (_spline == null) return distance;
    _distanceTravelled += distance;
    if (_distanceTravelled >= _spline!.totalLength) {
      final overflow = _distanceTravelled - _spline!.totalLength;
      _distanceTravelled = _spline!.totalLength;
      return overflow;
    }
    return 0.0;
  }

  void setT(double t) {
    if (_spline == null) return;
    _distanceTravelled = t.clamp(0.0, 1.0) * _spline!.totalLength;
  }

  double get distanceTravelled => _distanceTravelled;
}
