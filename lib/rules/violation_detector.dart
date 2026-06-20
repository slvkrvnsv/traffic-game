import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/game_bus.dart';
import '../core/utils.dart' show obbOverlap;
import '../cars/npc_car.dart';
import '../cars/player_car.dart';
import '../debug/debug_state.dart';
import '../pedestrians/pedestrian.dart';
import '../tiles/tile_manager.dart';

/// Runs each frame to detect violations and emit [RuleEvent]s to [GameBus].
class ViolationDetector extends Component {
  ViolationDetector({
    required this.playerCar,
    required this.tileManager,
    required this.pedestrians,
  });

  final PlayerCar playerCar;
  final TileManager tileManager;

  /// World-owned registry of live pedestrians (GameWorld.pedestrians).
  final List<Pedestrian> pedestrians;

  // Road-blocking timer — accrues only while the player is irrationally stopped
  // (clear road ahead, nothing requiring a wait).
  double _blockTimer = 0.0;
  bool _blockFired = false;

  @override
  void update(double dt) {
    _checkCollisions();
    _checkRoadBlocking(dt);
    // Yield-rule evaluation is owned by individual tiles
    // (see IntersectionTile.updateNpcSensors) — it's spatial and per-tile,
    // so a generic t-based check here would only cause false positives.
  }

  // ---------------------------------------------------------------------------
  // Collision detection
  // ---------------------------------------------------------------------------

  void _checkCollisions() {
    if (kDebugMode) {
      playerCar.debugIsColliding = false;
      DebugState.playerColliding = false;
      DebugState.nearestNpcGap = double.infinity;
      DebugState.npcCollisionLane = -1;
      for (final npc in tileManager.allNpcs) {
        npc.debugIsColliding = false;
      }
    }

    for (final npc in tileManager.allNpcs) {
      if (kDebugMode) {
        final d = playerCar.position.distanceTo(npc.position);
        if (d < DebugState.nearestNpcGap) DebugState.nearestNpcGap = d;
      }
      if (_carsOverlap(playerCar, npc)) {
        if (kDebugMode) {
          playerCar.debugIsColliding = true;
          npc.debugIsColliding = true;
          DebugState.playerColliding = true;
          DebugState.nearestNpcGap = 0;
          DebugState.npcCollisionLane = npc.laneIndex;
        }
        GameBus.instance.emit(CollisionEvent(otherType: 'npc_car'));
        return;
      }
    }

    for (final ped in pedestrians) {
      if (_playerHitsPedestrian(playerCar, ped)) {
        if (kDebugMode) {
          playerCar.debugIsColliding = true;
          DebugState.playerColliding = true;
          DebugState.npcCollisionLane = -1;
        }
        GameBus.instance.emit(CollisionEvent(otherType: 'pedestrian'));
        return;
      }
    }
  }

  bool _carsOverlap(PlayerCar a, NpcCar b) {
    return obbOverlap(
      a.position, kCarWidth, kCarLength, a.angle,
      b.position, kCarWidth, kCarLength, b.angle,
    );
  }

  bool _playerHitsPedestrian(PlayerCar a, Pedestrian ped) {
    // Compact, roughly square footprint for a top-down figure (orientation
    // barely matters for a person-sized box).
    return obbOverlap(
      a.position, kCarWidth, kCarLength, a.angle,
      ped.position, 12, 12, ped.angle,
    );
  }

  // ---------------------------------------------------------------------------
  // Road-blocking
  // ---------------------------------------------------------------------------

  /// Punish sitting still on a clear road with no reason to wait. A stop is
  /// rational — and therefore exempt — if the tile requires the player to wait
  /// (yield/red light/stop) or something is legitimately blocking the way
  /// ahead (a car or pedestrian). The timer only accrues while the standstill
  /// is irrational, so it never penalises a normal yield, queue, or crossing.
  void _checkRoadBlocking(double dt) {
    final tile = tileManager.activeTile;
    if (tile == null) return;

    final stopped = playerCar.speed < kStopSpeedThreshold;
    final hasReasonToWait = tile.playerMustWait || !_isPathAheadClear();

    if (stopped && !hasReasonToWait) {
      _blockTimer += dt;
      if (_blockTimer >= kRoadBlockGraceSeconds && !_blockFired) {
        _blockFired = true;
        GameBus.instance.emit(RoadBlockingEvent(duration: _blockTimer));
      }
    } else {
      _blockTimer = 0.0;
      _blockFired = false;
    }
  }

  /// True if there is no car or pedestrian close ahead in the player's lane.
  bool _isPathAheadClear() {
    final fwd = Vector2(cos(playerCar.angle), sin(playerCar.angle));
    for (final npc in tileManager.allNpcs) {
      if (_isAhead(npc.position, fwd, kClearPathAheadDistance, kCarWidth * 1.5)) {
        return false;
      }
    }
    for (final ped in pedestrians) {
      if (_isAhead(ped.position, fwd, kClearPathAheadDistance, kRoadWidth / 2)) {
        return false;
      }
    }
    return true;
  }

  /// Is [other] ahead of the player within [maxAhead] and within [maxLateral]
  /// of the player's forward axis (i.e. in the player's lane)?
  bool _isAhead(
      Vector2 other, Vector2 fwd, double maxAhead, double maxLateral) {
    final delta = other - playerCar.position;
    final ahead = delta.dot(fwd);
    if (ahead <= 0 || ahead > maxAhead) return false;
    final lateral = (delta - fwd * ahead).length;
    return lateral <= maxLateral;
  }
}
