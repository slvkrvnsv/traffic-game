import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/spline.dart';
import '../core/utils.dart';
import '../cars/npc_car.dart';
import '../cars/car_variants.dart';

/// Creates NPC cars and owns the live-NPC registry for one game session.
/// Instance-scoped (owned by TileManager) so a restart starts empty.
class NpcSpawner {
  NpcSpawner({Random? rng}) : rng = rng ?? Random();

  final Random rng;

  /// Every NPC currently alive in the world, across all tiles.
  final List<NpcCar> allNpcs = [];

  /// Spawn a single NPC on [path] at its entry edge (t = 0).
  /// [tileOrigin]/[tileAngle] are the owning tile's world placement.
  /// Returns null if the hard cap is already reached.
  NpcCar? spawnSingle({
    required Spline path,
    required Vector2 tileOrigin,
    required int laneIndex,
    double tileAngle = 0.0,
    bool isTurning = false,
  }) {
    if (allNpcs.length >= kNpcHardCap) return null;

    final def = CarVariants.all[rng.nextInt(CarVariants.all.length)];
    final speed = randomRange(rng, kNpcMinSpeed, kNpcMaxSpeed);

    final npc = NpcCar(definition: def, profileSpeed: speed);
    npc.laneIndex = laneIndex;
    // Enter already at cruise, not from a standstill. CarBase.speed defaults to
    // 0, so without this every spawned/refilled car would sit stopped at its
    // lane entry (the tile edge) and crawl up from zero — looking like cars
    // "stopping at a new tile entry". Collision-avoidance still caps it the same
    // frame, and the spawner's jammed/min-distance guards keep the entry clear.
    npc.speed = speed;
    npc.assignSpline(path, worldOffset: tileOrigin, worldAngle: tileAngle);
    npc.brain.isTurning = isTurning;

    npc.position = npc.splinePosition;
    npc.angle = npc.splineAngle;

    allNpcs.add(npc);
    return npc;
  }

  void cullDistant(Vector2 playerPosition, Vector2 playerForward) {
    allNpcs.removeWhere((npc) {
      final delta = npc.position - playerPosition;
      final dist = delta.length;
      // Always remove NPCs that have drifted far away in any direction (well
      // off-screen at the cull distance).
      final tooFar = dist > kNpcCullDistance;
      // Remove parked NPCs (spline finished) at a closer distance to free the
      // budget — but ONLY when they're behind the player. The same predicate
      // without the direction test was culling same-direction through-traffic
      // that had frozen *ahead* waiting for the next tile to stream in, making
      // cars vanish on-screen at the end of a tile.
      final behind = delta.dot(playerForward) < 0;
      final parkedAndBehind =
          npc.isAtSplineEnd && behind && dist > kNpcCullDistance * 0.25;
      final shouldCull = tooFar || parkedAndBehind;
      if (shouldCull) {
        npc.removeFromParent();
        debugPrint('[NPC] culled L${npc.laneIndex}'
            '  dist=${dist.toStringAsFixed(0)}'
            '  parked=${npc.isAtSplineEnd}');
      }
      return shouldCull;
    });
  }
}
