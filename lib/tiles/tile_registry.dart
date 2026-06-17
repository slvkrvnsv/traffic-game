import 'dart:math';
import '../core/maneuver.dart';
import 'tile_base.dart';

/// All available tile types.
enum TileType {
  straight,
  // Single lane each way (x=640 player / x=560 oncoming) — the lane geometry
  // the intersection uses, so it seams with both the intersection and the
  // 2-lane straight's inner lane. The road between lane transitions.
  straight1Lane,
  // Lane-transition connectors. laneMerge: the player's right lane ends and
  // merges left (2→1). laneExtend: a lane is added on the right (1→2), the
  // N-S mirror of a merge. See LaneTransitionTile.
  laneMerge,
  laneExtend,
  intersection4way,
  // The opening parking-lot tile. Placed only as the first tile (never
  // registered for random spawning), so it is absent from [allTypes].
  start,
  // Future: stopSign, trafficLight, roundabout, toll, cop, dealer
}

/// Per-spawn variation passed to tile factories. Tiles pick their own
/// randomness from [rng]; [maneuver] pins the commanded maneuver (test mode).
class TileSpawnContext {
  const TileSpawnContext({this.maneuver, this.rng});

  final Maneuver? maneuver;
  final Random? rng;
}

typedef TileFactory = TileBase Function(TileSpawnContext ctx);

/// Registry mapping [TileType] → factory function.
/// Tiles register themselves via [register]; [TileManager] uses [create].
class TileRegistry {
  TileRegistry._();

  static final Map<TileType, TileFactory> _factories = {};

  /// Types eligible for random free-drive spawning. A registered type can be
  /// [create]d on demand (e.g. as part of a fixed course) without being in the
  /// random pool — connectors and the 1-lane straight only seam correctly when
  /// chained, so they register with [spawnable] false to stay out of free drive.
  static final Set<TileType> _spawnable = {};

  static void register(
    TileType type,
    TileFactory factory, {
    bool spawnable = true,
  }) {
    _factories[type] = factory;
    if (spawnable) {
      _spawnable.add(type);
    } else {
      _spawnable.remove(type);
    }
  }

  static TileBase create(
    TileType type, [
    TileSpawnContext ctx = const TileSpawnContext(),
  ]) {
    final factory = _factories[type];
    assert(factory != null, 'No tile registered for $type');
    return factory!(ctx);
  }

  /// Types eligible for random free-drive spawning (and listed individually in
  /// the test menu). Excludes course-only tiles registered as non-spawnable.
  static List<TileType> get allTypes => _spawnable.toList();
}
