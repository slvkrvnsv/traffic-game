import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/start_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';

/// Lane switching is a multi-lane affordance: it must be on for the straight
/// road and off for single-lane maneuver tiles, so the player can't steer a
/// commanded turn. Pins TileBase.allowsLaneChange to the player-lane count.
void main() {
  group('TileBase.allowsLaneChange', () {
    test('the multi-lane straight road allows lane changes', () {
      final tile = StraightTile();
      expect(tile.playerPaths.length, greaterThan(1));
      expect(tile.allowsLaneChange, isTrue);
    });

    test('single-lane intersection maneuvers disallow lane changes', () {
      for (final m in Maneuver.values) {
        final tile = IntersectionTile(maneuver: m);
        expect(tile.playerPaths.length, 1, reason: 'maneuver $m');
        expect(tile.allowsLaneChange, isFalse, reason: 'maneuver $m');
      }
    });

    test('the single-lane start tile disallows lane changes', () {
      final tile = StartTile();
      expect(tile.allowsLaneChange, isFalse);
    });
  });
}
