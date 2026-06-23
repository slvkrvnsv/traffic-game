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
  // US all-way STOP. Every approach has a STOP sign; the player must come to a
  // complete stop at the line, even when the box is clear (a rolling stop is a
  // fault). See [IntersectionTile].
  intersection4way,
  // The opening parking-lot tile. Placed only as the first tile (never
  // registered for random spawning), so it is absent from [allTypes].
  start,
  // Future: trafficLight, roundabout, toll, cop, dealer
}

/// The setting a tile is dressed for. Orthogonal to both geometry ([TileType])
/// and the graded rule (scenario) — it only drives visual dressing and
/// pedestrian density:
///   * [interurban]: green countryside, scattered trees, passers-by very rare.
///   * [urban]: city surroundings (buildings), people on the sidewalks, and —
///     on intersections — zebra crossings everyone must yield to.
enum LocaleType { interurban, urban }

/// How a 4-way intersection is controlled — an all-way STOP or a traffic light.
/// Defined here (beside [TileType]) so the spawn context and the test menu can
/// pin it without importing the tile. The live read is `IntersectionTile.control`
/// (derived from the dressed scenario); this enum is also the test-mode override.
enum IntersectionControl { allWayStop, trafficLight }

/// Per-spawn variation passed to tile factories. Tiles pick their own
/// randomness from [rng]; [maneuver] pins the commanded maneuver (test mode);
/// [locale] dresses the tile (urban vs interurban) — see [LocaleType];
/// [control] pins an intersection's control (test mode) — null = roll it.
class TileSpawnContext {
  const TileSpawnContext(
      {this.maneuver,
      this.rng,
      this.locale = LocaleType.interurban,
      this.control});

  final Maneuver? maneuver;
  final Random? rng;
  final LocaleType locale;
  final IntersectionControl? control;
}

typedef TileFactory = TileBase Function(TileSpawnContext ctx);

/// How many lanes (player direction) a tile presents at its entry and exit
/// seam. Free-drive spawning chains tiles so the next tile's [entry] matches
/// the previous tile's [exit] — the road never gains or drops a lane except
/// through a connector that explicitly transitions (a 2→1 merge / 1→2 extend).
/// Symmetric about the centreline, so matching the player side matches oncoming
/// too. A tile is a *connector* when [entry] != [exit].
typedef TileLaneProfile = ({int entry, int exit});

/// Registry mapping [TileType] → factory function.
/// Tiles register themselves via [register]; [TileManager] uses [create].
class TileRegistry {
  TileRegistry._();

  static final Map<TileType, TileFactory> _factories = {};
  static final Map<TileType, TileLaneProfile> _laneProfiles = {};

  /// Types eligible for random free-drive spawning. A registered type can be
  /// [create]d on demand (e.g. as part of a fixed course) without being in the
  /// random pool — e.g. [TileType.start] is placed only as the first tile.
  static final Set<TileType> _spawnable = {};

  /// "Junction" tiles — those that interrupt a plain drive with a stop or
  /// right-of-way negotiation (an intersection; later a traffic light or
  /// roundabout). Free-drive keeps a plain road between any two interrupting
  /// tiles so the player is never asked to stop twice in a row.
  static final Set<TileType> _junctions = {};

  static void register(
    TileType type,
    TileFactory factory, {
    required int entryLanes,
    required int exitLanes,
    bool spawnable = true,
    bool junction = false,
  }) {
    _factories[type] = factory;
    _laneProfiles[type] = (entry: entryLanes, exit: exitLanes);
    if (spawnable) {
      _spawnable.add(type);
    } else {
      _spawnable.remove(type);
    }
    if (junction) {
      _junctions.add(type);
    } else {
      _junctions.remove(type);
    }
  }

  /// Whether [type] interrupts a plain drive (intersection / future signals).
  static bool isJunction(TileType type) => _junctions.contains(type);

  static TileBase create(
    TileType type, [
    TileSpawnContext ctx = const TileSpawnContext(),
  ]) {
    final factory = _factories[type];
    assert(factory != null, 'No tile registered for $type');
    return factory!(ctx);
  }

  /// Lane profile of a registered [type]. Every placed tile type (including
  /// [TileType.start]) is registered, so the free-drive chainer can always look
  /// up the previous tile's exit lane count.
  static TileLaneProfile laneProfile(TileType type) {
    final p = _laneProfiles[type];
    assert(p != null, 'No lane profile registered for $type');
    return p!;
  }

  static int entryLanesOf(TileType type) => laneProfile(type).entry;
  static int exitLanesOf(TileType type) => laneProfile(type).exit;

  /// A connector changes the lane count (a merge or an extend); a plain road or
  /// intersection keeps it.
  static bool isConnector(TileType type) {
    final p = laneProfile(type);
    return p.entry != p.exit;
  }

  /// Spawnable types whose entry seam carries [lanes] lanes — i.e. the tiles
  /// that can legally follow a tile exiting with [lanes] lanes.
  static List<TileType> spawnableWithEntryLanes(int lanes) =>
      _spawnable.where((t) => entryLanesOf(t) == lanes).toList();

  /// Types eligible for random free-drive spawning. Connectors and the 1-lane
  /// straight are included (the lane-match invariant chains them correctly); the
  /// test menu lists only the self-seaming tiles individually (see test_menu).
  static List<TileType> get allTypes => _spawnable.toList();
}
