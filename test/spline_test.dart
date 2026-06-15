import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/core/spline_follower.dart';

void main() {
  group('Spline', () {
    test('evaluate returns first point at t=0', () {
      final s = Spline([
        Vector2(0, 0),
        Vector2(100, 0),
        Vector2(200, 0),
      ]);
      final p = s.evaluate(0.0);
      expect(p.x, closeTo(0.0, 1.0));
      expect(p.y, closeTo(0.0, 1.0));
    });

    test('evaluate returns last point at t=1', () {
      final s = Spline([
        Vector2(0, 0),
        Vector2(100, 0),
        Vector2(200, 0),
      ]);
      final p = s.evaluate(1.0);
      expect(p.x, closeTo(200.0, 2.0));
      expect(p.y, closeTo(0.0, 2.0));
    });

    test('totalLength is approximately correct for a straight line', () {
      final s = Spline([
        Vector2(0, 0),
        Vector2(0, 100),
        Vector2(0, 200),
        Vector2(0, 300),
      ]);
      expect(s.totalLength, closeTo(300.0, 5.0));
    });

    test('tangent points in travel direction for a horizontal spline', () {
      final s = Spline([
        Vector2(0, 0),
        Vector2(100, 0),
        Vector2(200, 0),
        Vector2(300, 0),
      ]);
      final t = s.tangent(0.5);
      expect(t.x, greaterThan(0.9)); // mostly rightward
      expect(t.y.abs(), lessThan(0.2));
    });

    test('distanceToT converts correctly', () {
      final s = Spline([
        Vector2(0, 0),
        Vector2(0, 100),
        Vector2(0, 200),
        Vector2(0, 300),
      ]);
      final t = s.distanceToT(150.0);
      expect(t, closeTo(0.5, 0.05));
    });
  });

  group('SplineFollower', () {
    test('advanceByDistance moves t forward', () {
      final follower = _TestFollower();
      final s = Spline([
        Vector2(0, 0),
        Vector2(0, 100),
        Vector2(0, 200),
        Vector2(0, 300),
      ]);
      follower.assignSpline(s);
      follower.advanceByDistance(150);
      expect(follower.currentT, closeTo(0.5, 0.05));
    });

    test('hasReachedEnd returns true after advancing past end', () {
      final follower = _TestFollower();
      final s = Spline([
        Vector2(0, 0),
        Vector2(0, 100),
        Vector2(0, 200),
      ]);
      follower.assignSpline(s);
      follower.advanceByDistance(99999);
      expect(follower.hasReachedEnd, isTrue);
    });
  });
}

class _TestFollower with SplineFollower {}
