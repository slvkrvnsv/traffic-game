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
    npc.assignSpline(path, worldOffset: tileOrigin, worldAngle: tileAngle);
    npc.brain.isTurning = isTurning;

    npc.position = npc.splinePosition;
    npc.angle = npc.splineAngle;

    allNpcs.add(npc);
    return npc;
  }

  void cullDistant(Vector2 playerPosition) {
    allNpcs.removeWhere((npc) {
      final dist = playerPosition.distanceTo(npc.position);
      // Always remove NPCs that have drifted far behind.
      final tooFar = dist > kNpcCullDistance;
      // Remove parked NPCs (spline finished) once they're behind the camera.
      final parkedAndBehind = npc.isAtSplineEnd && dist > kNpcCullDistance * 0.25;
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
