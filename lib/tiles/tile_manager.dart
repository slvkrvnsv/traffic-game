import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/game_bus.dart';
import '../core/maneuver.dart';
import '../core/spline.dart';
import '../cars/player_car.dart';
import '../cars/npc_car.dart';
import '../npc/npc_spawner.dart';
import '../debug/debug_state.dart';
import 'tile_base.dart';
import 'tile_connector.dart';
import 'tile_registry.dart';
import 'definitions/start_tile.dart';

/// Manages the rolling window of live tiles.
///
/// Keeps [kTilesAhead] tiles alive ahead of the player, spawning the next
/// tile before the player reaches the end of the current one, and despawning
/// old tiles once the player has moved well past them.
class TileManager extends Component {
  TileManager({
    required this.playerCar,
    required this.world,
    this.testMode,
    this.testManeuver,
    Random? rng,
  }) : _rng = rng ?? Random();

  final PlayerCar playerCar;
  final World world;

  /// If set, always generate this tile type (test mode).
  final TileType? testMode;

  /// If set, pin the commanded maneuver on every spawned tile (test mode).
  final Maneuver? testManeuver;

  final Random _rng;
  final NpcSpawner _spawner = NpcSpawner();

  /// All live NPCs this session — owned by the spawner, exposed for the
  /// rules system (ViolationDetector).
  List<NpcCar> get allNpcs => _spawner.allNpcs;

  final List<TileBase> _activeTiles = [];

  /// Old tiles that have been handed off but are still potentially visible.
  /// Removed once far enough behind the player.
  final List<TileBase> _trailingTiles = [];

  // ---------------------------------------------------------------------------
  // Traffic density
  // ---------------------------------------------------------------------------

  /// Desired live NPC count per NPC-path per tile.
  static const int _targetNpcsPerPath = 2;

  /// How often (seconds) to check each path for missing traffic.
  static const double _refillInterval = 1.8;

  /// Don't spawn if the spawn point is within this distance of the player
  /// (prevents cars materialising on-screen).
  static const double _minSpawnDistFromPlayer = 520.0;

  double _refillClock = 0.0;

  TileBase? get currentTile =>
      _activeTiles.isNotEmpty ? _activeTiles.first : null;

  // ---------------------------------------------------------------------------
  // Bootstrap
  // ---------------------------------------------------------------------------

  void bootstrap() {
    _spawnInitialTile();
    _spawnNextTile();
  }

  TileBase _createTile(TileType type) =>
      TileRegistry.create(type, TileSpawnContext(maneuver: testManeuver, rng: _rng));

  void _activateTile(TileBase tile) {
    tile.onActivate();
    GameBus.instance
        .emit(ManeuverAnnouncedEvent(maneuver: tile.commandedManeuver));
  }

  void _spawnInitialTile() {
    // Normal play opens in the driving-school parking lot; test mode loops the
    // chosen tile from the start instead.
    final tile = testMode != null ? _createTile(testMode!) : StartTile();
    // First tile: canonical orientation, entry anchor at the world origin.
    tile.place(
      worldPosition: -tile.entryAnchor,
      orientation: 0.0,
    );
    _addTile(tile);

    _assignPlayerToTile(tile);
    playerCar.position.setFrom(playerCar.splinePosition);
    playerCar.angle = playerCar.splineAngle;

    _activateTile(tile);
    GameBus.instance.emit(TileReadyEvent(tileType: tile.tileType.name));
    debugPrint('[TILE] initial: ${tile.tileType.name} @ ${tile.position}');
  }

  void _assignPlayerToTile(TileBase tile) {
    playerCar.assignSpline(
      tile.playerPaths.first,
      worldOffset: tile.position,
      worldAngle: tile.orientation,
    );
  }

  // ---------------------------------------------------------------------------
  // Update loop
  // ---------------------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);
    _checkHandOff();
    _advanceNpcsAcrossSeams();
    _updateNpcSensors(dt);
    _cullDistantNpcs();
    _cullTrailingTiles();
    _tickRefill(dt);
    _updateDebugState();
  }

  void _updateNpcSensors(double dt) {
    for (final tile in _activeTiles) {
      tile.updateNpcSensors(dt, playerCar, _spawner.allNpcs);
    }
  }

  void _updateDebugState() {
    if (!kDebugMode) return;
    final tile = activeTile;
    if (tile != null) DebugState.updateFromTile(tile);
    DebugState.activeTileCount = _activeTiles.length;
    DebugState.activeTileNames =
        _activeTiles.map((t) => '${t.tileType.name} @ (${t.position.x.toStringAsFixed(0)}, ${t.position.y.toStringAsFixed(0)})').toList();
    DebugState.playerSpeed = playerCar.speed;
    DebugState.playerT = playerCar.currentT;
    DebugState.playerX = playerCar.position.x;
    DebugState.playerY = playerCar.position.y;
    DebugState.playerBraking = playerCar.isBraking;
    DebugState.updateNpcs(_spawner.allNpcs);
  }

  void _checkHandOff() {
    final tile = currentTile;
    if (tile == null) return;

    // Spawn next tile early so it's ready when the player arrives.
    if (playerCar.currentT >= kHandOffTriggerT &&
        _activeTiles.length < kTilesAhead + 1) {
      _spawnNextTile();
    }

    // Hand off when the player has reached the exact end of the current spline.
    // Using hasReachedEnd (t=1.0) ensures the new spline's t=0 maps to the
    // same world position — no jump.
    if (_activeTiles.length >= 2 && playerCar.hasReachedEnd) {
      _handOffToNextTile();
    }
  }

  void _handOffToNextTile() {
    final oldTile = _activeTiles.removeAt(0);
    oldTile.onDeactivate();

    final newTile = _activeTiles.first;
    _activateTile(newTile);

    // NPC continuity across the seam is handled continuously every frame by
    // _advanceNpcsAcrossSeams(), independent of the player's hand-off.

    _assignPlayerToTile(newTile);

    debugPrint('[TILE] handoff: ${oldTile.tileType.name} → ${newTile.tileType.name}'
        '  NPCs total=${_spawner.allNpcs.length}');

    GameBus.instance.emit(TileCompletedEvent(tileType: oldTile.tileType.name));
    GameBus.instance.emit(PlayerHandOffEvent());

    // Keep old tile in the world until it's far behind the camera.
    _trailingTiles.add(oldTile);
  }

  // ---------------------------------------------------------------------------
  // Continuous NPC seam hand-off
  // ---------------------------------------------------------------------------

  /// Every frame, carry any NPC that has reached the end of its lane onto a
  /// connecting lane on a live tile, matched purely by geometry (seam position
  /// + travel direction). This keeps through-traffic flowing seamlessly and
  /// stops cars freezing at tile boundaries. NPCs with no continuation either
  /// despawn (behind the player) or briefly wait (ahead, off-screen) until the
  /// next tile streams in.
  void _advanceNpcsAcrossSeams() {
    // Snapshot first — we mutate tile.npcs lists while iterating.
    final reached = <(NpcCar, TileBase)>[];
    for (final tile in _activeTiles) {
      for (final npc in tile.npcs) {
        if (npc.hasReachedEnd) reached.add((npc, tile));
      }
    }
    if (reached.isEmpty) return;

    final playerFwd = Vector2(cos(playerCar.angle), sin(playerCar.angle));

    for (final (npc, tile) in reached) {
      final next = _findContinuation(npc);
      if (next != null) {
        // Carry momentum (speed is untouched) and the overflow distance so the
        // car re-enters the new lane exactly where it left off.
        npc.assignSpline(
          next.path,
          startDistance: npc.pendingOverflow.clamp(0.0, next.path.totalLength),
          worldOffset: next.tile.position,
          worldAngle: next.tile.orientation,
        );
        npc.pendingOverflow = 0.0;
        npc.laneIndex = next.lane;
        // The continuation may bend (e.g. a turn through the next
        // intersection) — keep the indicator/turn-slow-down machinery honest.
        npc.brain.isTurning = TileBase.pathTurns(next.path);
        tile.npcs.remove(npc);
        next.tile.npcs.add(npc);
        continue;
      }

      // No continuation. Only same-direction through-traffic still ahead of the
      // player is worth holding for — the tile ahead just hasn't streamed in
      // yet (and it's off-screen anyway). Everything else (oncoming/cross
      // traffic, or anything behind the player) has driven off the playable
      // corridor and despawns cleanly.
      final npcDir = Vector2(cos(npc.angle), sin(npc.angle));
      final sameWayAsPlayer = npcDir.dot(playerFwd) > 0.7;
      final ahead = (npc.position - playerCar.position).dot(playerFwd) >= 0;

      if (sameWayAsPlayer && ahead) {
        npc.speed = 0.0;
        npc.targetSpeed = 0.0;
      } else {
        npc.removeFromParent();
        _spawner.allNpcs.remove(npc);
        tile.npcs.remove(npc);
      }
    }
  }

  /// Find a lane on any live tile that continues [npc]'s travel past the seam
  /// it just reached. Matches by world seam proximity and heading agreement.
  /// When several movements share the matched entry (an intersection lane
  /// offering straight/left/right), one is picked at random so through-traffic
  /// turns like real cars.
  ({TileBase tile, Spline path, int lane})? _findContinuation(NpcCar npc) {
    final endPos = npc.position;
    final endDir = Vector2(cos(npc.angle), sin(npc.angle));
    final current = npc.spline;

    const double seamTolerance = 30.0; // world units
    final candidates = <({TileBase tile, Spline path, int lane})>[];
    double bestDist = seamTolerance;

    for (final tile in [..._activeTiles, ..._trailingTiles]) {
      for (int lane = 0; lane < tile.npcLanes.length; lane++) {
        for (final path in tile.npcLanes[lane]) {
          if (identical(path, current)) continue; // never re-enter the same lane
          final start = tile.localToWorld(path.evaluate(0.0));
          final d = start.distanceTo(endPos);
          if (d > bestDist + 1.0) continue;
          if (tile.directionToWorld(path.tangent(0.0)).dot(endDir) < 0.7) {
            continue; // must head the same way
          }
          if (d < bestDist - 1.0) candidates.clear(); // strictly better seam
          bestDist = min(bestDist, d);
          candidates.add((tile: tile, path: path, lane: lane));
        }
      }
    }
    if (candidates.isEmpty) return null;
    return candidates[_rng.nextInt(candidates.length)];
  }

  // ---------------------------------------------------------------------------
  // Tile spawning
  // ---------------------------------------------------------------------------

  /// How many times to re-roll a tile whose footprint would overlap live
  /// tiles (a turn folding the corridor back onto itself) before giving up
  /// and accepting the overlap (degenerate but never deadlocks).
  static const int _placementRetries = 6;

  void _spawnNextTile() {
    final prevTile = _activeTiles.last;

    TileBase tile = _createTile(_pickNextTileType());
    TilePlacement placement = TileConnector.computeNextPlacement(prevTile, tile);

    final liveTiles = [..._activeTiles, ..._trailingTiles];
    for (int attempt = 0;
        attempt < _placementRetries &&
            TileConnector.overlapsAny(placement, liveTiles);
        attempt++) {
      tile = _createTile(_pickNextTileType());
      placement = TileConnector.computeNextPlacement(prevTile, tile);
    }

    tile.place(
      worldPosition: placement.worldPosition,
      orientation: placement.orientation,
    );
    _addTile(tile);

    debugPrint('[TILE] spawned: ${tile.tileType.name} @ ${tile.position}'
        '  rot=${(tile.orientation * 180 / pi).round()}°');
    GameBus.instance.emit(TileReadyEvent(tileType: tile.tileType.name));
  }

  void _addTile(TileBase tile) {
    world.add(tile);
    _activeTiles.add(tile);
    _spawnNpcsForTile(tile);
  }

  void _spawnNpcsForTile(TileBase tile) {
    int count = 0;
    for (int lane = 0; lane < tile.npcLanes.length; lane++) {
      final path = _pickMovement(tile, lane);
      final spawnPos = tile.localToWorld(path.evaluate(0.0));
      // Same guard as the refill path: don't materialise a car on top of the player.
      if (playerCar.position.distanceTo(spawnPos) < _minSpawnDistFromPlayer) {
        continue;
      }
      final npc = _spawnOnPath(tile, lane, path);
      if (npc == null) break; // hard cap
      count++;
    }
    debugPrint('[NPC] spawned $count for ${tile.tileType.name}'
        '  total=${_spawner.allNpcs.length}');
  }

  /// Pick a random movement for [lane] — on intersections this is what makes
  /// NPC traffic turn left/right like real cars instead of only driving
  /// straight through.
  Spline _pickMovement(TileBase tile, int lane) {
    final group = tile.npcLanes[lane];
    return group[_rng.nextInt(group.length)];
  }

  NpcCar? _spawnOnPath(TileBase tile, int lane, Spline path) {
    final npc = _spawner.spawnSingle(
      path: path,
      tileOrigin: tile.position,
      tileAngle: tile.orientation,
      laneIndex: lane,
      isTurning: TileBase.pathTurns(path),
    );
    if (npc == null) return null; // hard cap
    tile.npcs.add(npc);
    world.add(npc);
    return npc;
  }

  TileType _pickNextTileType() {
    if (testMode != null) return testMode!;
    final types = TileRegistry.allTypes;
    return types[_rng.nextInt(types.length)];
  }

  // ---------------------------------------------------------------------------
  // NPC culling
  // ---------------------------------------------------------------------------

  void _cullDistantNpcs() {
    _spawner.cullDistant(playerCar.position);
  }

  // ---------------------------------------------------------------------------
  // Trailing tile culling
  // ---------------------------------------------------------------------------

  /// Remove old tiles once the camera has clearly moved past them.
  void _cullTrailingTiles() {
    _trailingTiles.removeWhere((tile) {
      if (playerCar.position.distanceTo(tile.worldCenter) > kTileSize * 1.2) {
        tile.removeFromParent();
        debugPrint('[TILE] removed trailing: ${tile.tileType.name}');
        return true;
      }
      return false;
    });
  }

  // ---------------------------------------------------------------------------
  // Traffic refill
  // ---------------------------------------------------------------------------

  void _tickRefill(double dt) {
    _refillClock += dt;
    if (_refillClock < _refillInterval) return;
    _refillClock = 0.0;
    _refillTraffic();
  }

  /// For every NPC lane on every active tile, count alive NPCs and spawn one
  /// at the lane entry edge if the count is below [_targetNpcsPerPath].
  void _refillTraffic() {
    for (final tile in _activeTiles) {
      for (int lane = 0; lane < tile.npcLanes.length; lane++) {
        // Count NPCs still alive that belong to this tile + lane.
        final alive = tile.npcs
            .where((n) =>
                n.laneIndex == lane && _spawner.allNpcs.contains(n))
            .length;
        if (alive < _targetNpcsPerPath) {
          _trySpawnOnLane(tile, lane);
        }
      }
    }
  }

  /// Attempt to spawn one NPC at the entry edge of [tile]'s lane [laneIndex].
  /// Skipped if the spawn point is on-screen or another NPC is too close.
  void _trySpawnOnLane(TileBase tile, int laneIndex) {
    final path = _pickMovement(tile, laneIndex);
    final spawnPos = tile.localToWorld(path.evaluate(0.0));

    // Don't materialise a car in front of the player.
    if (playerCar.position.distanceTo(spawnPos) < _minSpawnDistFromPlayer) {
      return;
    }

    // Don't spawn if the entry point is jammed (another car is right there).
    final jammed = _spawner.allNpcs.any(
        (n) => n.position.distanceTo(spawnPos) < kNpcSafeGapDistance * 2.0);
    if (jammed) return;

    final npc = _spawnOnPath(tile, laneIndex, path);
    if (npc == null) return; // hard cap

    debugPrint('[NPC] refill L$laneIndex on ${tile.tileType.name}'
        '  total=${_spawner.allNpcs.length}');
  }

  // ---------------------------------------------------------------------------
  // Accessors for rules system
  // ---------------------------------------------------------------------------

  TileBase? get activeTile =>
      _activeTiles.isNotEmpty ? _activeTiles.first : null;
}
