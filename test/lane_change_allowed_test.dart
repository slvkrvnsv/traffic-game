import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/start_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';

/// `allowsLaneChange` now means "steering is ON", not "there are ≥2 lanes". It's on
/// for the multi-lane straight road (merge) AND for the single-lane intersection
/// (the player must STEER the commanded turn at the box — the turn taps + the
/// cosmetic intention lean), and off only where the player shouldn't steer (start).
void main() {
  group('TileBase.allowsLaneChange', () {
    test('the multi-lane straight road allows lane changes', () {
      final tile = StraightTile();
      expect(tile.playerPaths.length, greaterThan(1));
      expect(tile.allowsLaneChange, isTrue);
    });

    test('single-lane intersection enables turn-steering (taps + lean)', () {
      for (final m in Maneuver.values) {
        final tile = IntersectionTile(maneuver: m);
        // ONE player lane (the through-spine) — nothing to MERGE into...
        expect(tile.playerPaths.length, 1, reason: 'maneuver $m');
        // ...but steering is ON so the player can steer the commanded turn.
        expect(tile.allowsLaneChange, isTrue, reason: 'maneuver $m');
      }
    });

    test('the single-lane start tile disallows lane changes', () {
      final tile = StartTile();
      expect(tile.allowsLaneChange, isFalse);
    });
  });
}
