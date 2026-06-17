import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_one_lane_tile.dart';
import 'package:traffic_game/tiles/tile_registry.dart';

/// The connector tiles only chain cleanly if every tile seams on the inner lane
/// (x=640) and the merge keeps its commanded-transition properties. These pin
/// the geometry the Connectors course relies on.
void main() {
  const seamX = 640.0; // shared inner/seam lane across all road tiles

  group('StraightOneLaneTile', () {
    final tile = StraightOneLaneTile();

    test('is a single player lane on the seam, no lane changes', () {
      expect(tile.playerPaths.length, 1);
      expect(tile.entryAnchor.x, seamX);
      expect(tile.exitAnchor.x, seamX);
      expect(tile.allowsLaneChange, isFalse);
    });

    test('declares the straight1Lane type', () {
      expect(tile.tileType, TileType.straight1Lane);
    });
  });

  group('LaneTransitionTile — merge (2→1)', () {
    final tile = LaneTransitionTile(merging: true);

    test('has two player paths and allows steering (merge yourself)', () {
      expect(tile.playerPaths.length, 2);
      expect(tile.allowsLaneChange, isTrue); // can move over early when safe
    });

    test('seams on the inner lane at both ends', () {
      expect(tile.entryAnchor.x, seamX);
      expect(tile.exitAnchor.x, seamX);
    });

    test('the merge lane runs from the outer lane into the inner lane', () {
      final merge = tile.playerPaths[1];
      expect(merge.evaluate(0.0).x, greaterThan(seamX + 40)); // starts outer
      expect(merge.evaluate(1.0).x, closeTo(seamX, 1.0)); // ends on the seam
    });

    test('the merge lane is monotonic — never bends right before going left',
        () {
      // The car travels t=0 (outer, x≈720) → t=1 (inner, x=640): x must only
      // ever decrease. Any increase is the Catmull-Rom overshoot we removed.
      final merge = tile.playerPaths[1];
      double prevX = merge.evaluate(0.0).x;
      for (int i = 1; i <= 100; i++) {
        final x = merge.evaluate(i / 100).x;
        expect(x, lessThanOrEqualTo(prevX + 0.5),
            reason: 'x rose at t=${i / 100} ($prevX → $x)');
        prevX = x;
      }
    });

    test('declares the laneMerge type with no commanded maneuver', () {
      expect(tile.commandedManeuver, isNull);
      expect(tile.tileType, TileType.laneMerge);
    });

    test('has no static task label — "Merge left" is announced dynamically '
        'only while the player is in the ending lane', () {
      // Lane-scoped: a player who stays in the through lane is never told to
      // merge and is never graded (see merge_scenario_test.dart).
      expect(tile.taskLabel, isNull);
    });
  });

  group('LaneTransitionTile — extend (1→2)', () {
    final tile = LaneTransitionTile(merging: false);

    test('seams on the inner lane, no task, but is drivable', () {
      expect(tile.entryAnchor.x, seamX);
      expect(tile.exitAnchor.x, seamX);
      expect(tile.taskLabel, isNull); // nothing graded — "just go"
      expect(tile.tileType, TileType.laneExtend);
      // Two player paths (through + the diverging right lane) and steering ON,
      // so the player can move into the new lane as it opens.
      expect(tile.playerPaths.length, 2);
      expect(tile.allowsLaneChange, isTrue);
    });

    test('the diverging lane opens from the seam out to the right', () {
      final diverge = tile.playerPaths[1];
      expect(diverge.evaluate(0.0).x, closeTo(seamX, 1.0)); // starts on the seam
      expect(diverge.evaluate(1.0).x, greaterThan(seamX + 40)); // opens right
    });
  });
}
