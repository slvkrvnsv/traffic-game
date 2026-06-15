import 'dart:math';
import '../core/maneuver.dart';
import 'tile_base.dart';

/// All available tile types.
enum TileType {
  straight,
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

  static void register(TileType type, TileFactory factory) {
    _factories[type] = factory;
  }

  static TileBase create(
    TileType type, [
    TileSpawnContext ctx = const TileSpawnContext(),
  ]) {
    final factory = _factories[type];
    assert(factory != null, 'No tile registered for $type');
    return factory!(ctx);
  }

  static List<TileType> get allTypes => _factories.keys.toList();
}
