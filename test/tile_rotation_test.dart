import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/core/spline_follower.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/tile_connector.dart';

class _Follower with SplineFollower {}

void expectVector(Vector2 actual, Vector2 expected, {double eps = 0.001}) {
  expect(actual.x, closeTo(expected.x, eps), reason: 'x of $actual vs $expected');
  expect(actual.y, closeTo(expected.y, eps), reason: 'y of $actual vs $expected');
}

void main() {
  group('SplineFollower world transform', () {
    test('applies offset and rotation to position and angle', () {
      // Local spline heading north (-y) from (10, 100) to (10, 0).
      final spline = Spline([
        Vector2(10, 100),
        Vector2(10, 50),
        Vector2(10, 0),
      ]);
      final f = _Follower();
      // Rotate 90° clockwise (north → east) and offset.
      f.assignSpline(spline,
          worldOffset: Vector2(1000, 2000), worldAngle: math.pi / 2);

      // t=0: local (10,100) → rotated (−100, 10) → +offset.
      expectVector(f.splinePosition, Vector2(900, 2010));
      // Heading north locally (−π/2) + π/2 → 0 (east).
      expect(f.splineAngle, closeTo(0.0, 0.01));

      f.advanceByDistance(spline.totalLength);
      // t=1: local (10, 0) → rotated (0, 10) → +offset.
      expectVector(f.splinePosition, Vector2(1000, 2010));
    });
  });

  group('TileConnector placement', () {
    test('straight tile after a right-turn intersection heads east', () {
      final inter = IntersectionTile(maneuver: Maneuver.right);
      inter.place(worldPosition: Vector2.zero(), orientation: 0.0);
      expectVector(inter.worldExitDirection, Vector2(1, 0));

      final next = StraightTile();
      final placement = TileConnector.computeNextPlacement(inter, next);
      next.place(
        worldPosition: placement.worldPosition,
        orientation: placement.orientation,
      );

      // Corridor continuity: entry lands exactly on the previous exit,
      // heading the same way.
      expectVector(next.worldEntry, inter.worldExit);
      expectVector(next.worldExitDirection, Vector2(1, 0));

      // Player spline continuity across the seam (t=1 on prev == t=0 on next).
      final prevEnd = inter.localToWorld(inter.playerPaths.first.evaluate(1.0));
      final nextStart = next.localToWorld(next.playerPaths.first.evaluate(0.0));
      expectVector(nextStart, prevEnd, eps: 0.5);
    });

    test('left turn rotates the corridor counter-clockwise', () {
      final inter = IntersectionTile(maneuver: Maneuver.left);
      inter.place(worldPosition: Vector2.zero(), orientation: 0.0);

      final next = StraightTile();
      final placement = TileConnector.computeNextPlacement(inter, next);
      next.place(
        worldPosition: placement.worldPosition,
        orientation: placement.orientation,
      );

      expectVector(next.worldEntry, inter.worldExit);
      expectVector(next.worldExitDirection, Vector2(-1, 0));
    });

    test('chained straights keep heading north and never overlap', () {
      final a = StraightTile()
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final placement =
          TileConnector.computeNextPlacement(a, StraightTile());
      final b = StraightTile()
        ..place(
          worldPosition: placement.worldPosition,
          orientation: placement.orientation,
        );

      expectVector(b.worldEntry, a.worldExit);
      expect(TileConnector.overlapsAny(placement, b.size, [a]), isFalse);
    });

    test('footprint guard rejects a tile placed on top of another', () {
      final a = StraightTile()
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final placement =
          TilePlacement(worldPosition: Vector2.zero(), orientation: 0.0);
      expect(TileConnector.overlapsAny(placement, a.size, [a]), isTrue);
    });
  });

  group('Intersection movement conflicts', () {
    // NPC lanes: 0 = N-bound (same as player), 1 = E-bound, 2 = S-bound
    // (oncoming), 3 = W-bound.
    test('straight conflicts with cross traffic only', () {
      final tile = IntersectionTile(maneuver: Maneuver.straight);
      expect(tile.playerConflictsWithLane(0), isFalse, reason: 'same lane queue');
      expect(tile.playerConflictsWithLane(1), isTrue, reason: 'crosses E-bound');
      expect(tile.playerConflictsWithLane(2), isFalse, reason: 'parallel oncoming');
      expect(tile.playerConflictsWithLane(3), isTrue, reason: 'crosses W-bound');
    });

    test('left turn conflicts with oncoming and both cross directions', () {
      final tile = IntersectionTile(maneuver: Maneuver.left);
      expect(tile.playerConflictsWithLane(0), isFalse);
      expect(tile.playerConflictsWithLane(1), isTrue, reason: 'crosses E-bound');
      expect(tile.playerConflictsWithLane(2), isTrue, reason: 'crosses oncoming');
      expect(tile.playerConflictsWithLane(3), isTrue, reason: 'merges into W-bound');
    });

    test('right turn only merges with E-bound traffic', () {
      final tile = IntersectionTile(maneuver: Maneuver.right);
      expect(tile.playerConflictsWithLane(0), isFalse);
      expect(tile.playerConflictsWithLane(1), isTrue, reason: 'merges into E-bound');
      expect(tile.playerConflictsWithLane(2), isFalse, reason: 'never crosses oncoming');
      expect(tile.playerConflictsWithLane(3), isFalse, reason: 'never reaches W-bound lane');
    });
  });

  group('NPC movement lanes (4 approaches × 3 maneuvers)', () {
    // Lane order matches Heading.values: 0=N-bound (south approach),
    // 1=E-bound (west), 2=S-bound (north), 3=W-bound (east).
    final tile = IntersectionTile();

    test('every approach offers all three movements from one entry point', () {
      expect(tile.npcLanes.length, 4);
      for (final lane in tile.npcLanes) {
        expect(lane.length, Maneuver.values.length);
        final entry = lane.first.evaluate(0.0);
        for (final path in lane) {
          expectVector(path.evaluate(0.0), entry);
        }
      }
      // Entries sit on the correct edge for each approach.
      expectVector(tile.npcLanes[0].first.evaluate(0.0), Vector2(640, 1200));
      expectVector(tile.npcLanes[1].first.evaluate(0.0), Vector2(0, 640));
      expectVector(tile.npcLanes[2].first.evaluate(0.0), Vector2(560, 0));
      expectVector(tile.npcLanes[3].first.evaluate(0.0), Vector2(1200, 560));
    });

    test('rotated turns exit onto the correct lanes', () {
      // E-bound left turn exits north on the N-bound lane.
      expectVector(
          tile.npcLanes[1][Maneuver.left.index].evaluate(1.0), Vector2(640, 0));
      // E-bound right turn exits south on the S-bound lane.
      expectVector(tile.npcLanes[1][Maneuver.right.index].evaluate(1.0),
          Vector2(560, 1200));
      // W-bound right turn (from the east) exits north on the N-bound lane.
      expectVector(tile.npcLanes[3][Maneuver.right.index].evaluate(1.0),
          Vector2(640, 0));
    });

    test('pathTurns flags turn movements and not straights', () {
      for (final lane in tile.npcLanes) {
        expect(TileBase.pathTurns(lane[Maneuver.straight.index]), isFalse);
        expect(TileBase.pathTurns(lane[Maneuver.left.index]), isTrue);
        expect(TileBase.pathTurns(lane[Maneuver.right.index]), isTrue);
      }
    });

    test('NPC right-of-way conflicts follow real traffic semantics', () {
      // Opposite straights run in parallel — no conflict.
      expect(
          tile.npcMovementsConflict(
              0, Maneuver.straight, 2, Maneuver.straight),
          isFalse);
      // A left turn crosses the oncoming straight.
      expect(tile.npcMovementsConflict(0, Maneuver.left, 2, Maneuver.straight),
          isTrue);
      // Opposite right turns stay in their own corners.
      expect(tile.npcMovementsConflict(0, Maneuver.right, 2, Maneuver.right),
          isFalse);
      // Cross straights conflict (the classic yield-to-the-right case).
      expect(
          tile.npcMovementsConflict(
              0, Maneuver.straight, 1, Maneuver.straight),
          isTrue);
    });
  });
}
