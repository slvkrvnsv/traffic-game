import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_one_lane_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/start_tile.dart';

/// The free-drive chainer must keep the road lane-continuous: a lane is only
/// ever gained or dropped through a connector, never by popping in/out.
void main() {
  setUpAll(() {
    // main() doesn't run in tests — register the tile types ourselves.
    StraightTile.register();
    StraightOneLaneTile.register();
    LaneTransitionTile.register();
    IntersectionTile.register();
    StartTile.register();
  });

  test('every placed tile type has a lane profile (no null bootstrap lookup)',
      () {
    for (final t in TileType.values) {
      expect(() => TileRegistry.laneProfile(t), returnsNormally,
          reason: '$t must be registered with a lane profile');
    }
  });

  test('neither lane state can deadlock the chainer', () {
    expect(TileRegistry.spawnableWithEntryLanes(1), isNotEmpty);
    expect(TileRegistry.spawnableWithEntryLanes(2), isNotEmpty);
  });

  test('a long free-drive chain is lane-continuous and never chains two '
      'interrupting tiles (connector/junction) back-to-back', () {
    bool interrupts(TileType t) =>
        TileRegistry.isConnector(t) || TileRegistry.isJunction(t);

    final rng = Random(42);
    var prev = TileType.start; // the chain always opens on the start tile
    for (int i = 0; i < 5000; i++) {
      final next = TileManager.pickFreeDriveType(prev, rng);

      expect(TileRegistry.entryLanesOf(next), TileRegistry.exitLanesOf(prev),
          reason: 'lane popped: $prev (exit ${TileRegistry.exitLanesOf(prev)}) '
              '→ $next (entry ${TileRegistry.entryLanesOf(next)})');

      if (interrupts(prev)) {
        expect(interrupts(next), isFalse,
            reason: 'two interrupting tiles back-to-back '
                '(width-flap / double-stop): $prev → $next');
      }
      prev = next;
    }
  });

  test('the matched adjacencies are exactly the intended ones', () {
    // 2-lane exit → another 2-lane road or a 2→1 merge.
    expect(TileRegistry.spawnableWithEntryLanes(2).toSet(),
        {TileType.straight, TileType.laneMerge});
    // 1-lane exit → a 1-lane road, the intersection, or a 1→2 extend.
    expect(TileRegistry.spawnableWithEntryLanes(1).toSet(),
        {TileType.straight1Lane, TileType.intersection4way, TileType.laneExtend});
  });
}
