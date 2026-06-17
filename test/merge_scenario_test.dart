import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/core/utils.dart';
import 'package:traffic_game/cars/car_variants.dart';
import 'package:traffic_game/cars/npc_car.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';
import 'package:traffic_game/tiles/scenarios/merge_scenario.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';
import 'package:traffic_game/tiles/scenarios/scenario_registry.dart';
import 'package:traffic_game/tiles/tile_registry.dart';

/// Two layers of cover for the merge rule:
///   1. MergeScenario bookkeeping — the lane-scoped pass/fail.
///   2. NPC merge *dynamics* — the actual behaviour the player sees (a merging
///      car yields to through traffic, never overlaps it, signals left, and is
///      NOT frozen at the wide entry). This is the layer a pass/fail-only test
///      misses, so it's checked by stepping the sensor + brain + motion.
void main() {
  group('MergeScenario (lane-scoped grading)', () {
    test('a cut-off does NOT fail when the player is in the through lane', () {
      final s = MergeScenario()..playerIsMerging = false;
      s.onDriverReaction();
      expect(s.result.status, ScenarioStatus.ongoing,
          reason: 'through-lane player has priority — "just go", no fault');
    });

    test('a cut-off fails when the player is the one merging', () {
      final s = MergeScenario()..playerIsMerging = true;
      s.onDriverReaction();
      expect(s.result.status, ScenarioStatus.failed);
      expect(s.result.reason, contains('cut off'));
    });

    test('a clean clear passes; a post-fault clear does not overwrite', () {
      expect((MergeScenario()..onSafelyCleared()).result.status,
          ScenarioStatus.passed);
      final failed = MergeScenario()
        ..playerIsMerging = true
        ..onDriverReaction()
        ..onSafelyCleared();
      expect(failed.result.status, ScenarioStatus.failed);
    });

    test('the laneMerge tile is dressed with MergeScenario', () {
      expect(ScenarioRegistry.forTile(TileType.laneMerge), isA<MergeScenario>());
    });
  });

  group('NPC merge dynamics', () {
    late LaneTransitionTile tile;
    late Spline mergeLane;
    late Spline throughLane;
    late PlayerCar player; // off-tile (no spline) — neutral for NPC-only checks

    setUp(() {
      tile = LaneTransitionTile(merging: true)
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      // npcPaths order is [oncoming, through, merge].
      throughLane = tile.npcPaths[1];
      mergeLane = tile.npcPaths[2];
      player = PlayerCar();
    });

    /// An NPC on [path] (lane [laneIndex]) placed near tile-local y=[targetY].
    NpcCar npcAt(Spline path, int laneIndex, double targetY,
        {double speed = 0}) {
      final npc = NpcCar(
          definition: CarVariants.all.first, profileSpeed: kmhToUnits(40));
      npc.laneIndex = laneIndex;
      npc.assignSpline(path,
          startDistance: (kTileSize - targetY).clamp(0.0, path.totalLength),
          worldOffset: Vector2.zero());
      npc.speed = speed;
      npc.position = npc.splinePosition;
      npc.angle = npc.splineAngle;
      return npc;
    }

    double localY(NpcCar n) => tile.worldToLocal(n.position).y;

    test('a merge car yields (slows) and signals left for through traffic '
        'in the taper', () {
      final merge = npcAt(mergeLane, 2, 650, speed: kmhToUnits(40));
      final through = npcAt(throughLane, 1, 600, speed: kmhToUnits(40));
      tile.npcs.addAll([merge, through]);

      tile.updateNpcSensors(1 / 60, player, tile.npcs);
      expect(merge.brain.signalLeftForMerge, isTrue,
          reason: 'merging car signals left across the move');

      merge.brain.update(1 / 60, merge);
      expect(merge.brain.desiredSpeed, lessThan(merge.profileSpeed),
          reason: 'gives way to the through car alongside-ahead');
      expect(merge.leftIndicatorVisible, isTrue);
    });

    test('a merge car at the wide entry does NOT freeze (the "standing there" '
        'bug) — lanes are still fully separate there', () {
      // Above _taperStartY (900) the outer lane is its own; a through car running
      // parallel must not make the merge car brake.
      final merge = npcAt(mergeLane, 2, 1120, speed: kmhToUnits(40));
      final through = npcAt(throughLane, 1, 1120, speed: kmhToUnits(40));
      tile.npcs.addAll([merge, through]);

      tile.updateNpcSensors(1 / 60, player, tile.npcs);
      expect(merge.brain.signalLeftForMerge, isFalse);

      merge.brain.update(1 / 60, merge);
      expect(merge.brain.desiredSpeed, greaterThan(merge.profileSpeed * 0.9),
          reason: 'no through-traffic conflict yet → keeps cruising');
    });

    test('a merged NPC (past the pinch) drops the left signal', () {
      final merge = npcAt(mergeLane, 2, 150); // below _taperEndY (250) → merged
      tile.npcs.add(merge);
      tile.updateNpcSensors(1 / 60, player, tile.npcs);
      expect(merge.brain.signalLeftForMerge, isFalse,
          reason: 'indicator turns off once merged');
    });

    test('a merging car and a through car never overlap as the lanes converge',
        () {
      final merge = npcAt(mergeLane, 2, 720, speed: kmhToUnits(40));
      final through = npcAt(throughLane, 1, 620, speed: kmhToUnits(40));
      tile.npcs.addAll([merge, through]);

      const dt = 1 / 60;
      for (int i = 0; i < 180; i++) {
        tile.updateNpcSensors(dt, player, tile.npcs);
        merge.update(dt);
        through.update(dt);
        final overlap = obbOverlap(
          merge.position, kCarWidth, kCarLength, merge.angle,
          through.position, kCarWidth, kCarLength, through.angle,
        );
        expect(overlap, isFalse,
            reason: 'cars must never pass through each other '
                '(frame $i, merge y=${localY(merge).toStringAsFixed(0)})');
      }
    });
  });

  group('Player merge signaling (auto left indicator)', () {
    late LaneTransitionTile tile;
    setUp(() {
      tile = LaneTransitionTile(merging: true)
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    });

    PlayerCar playerOn(Spline path, double y) {
      final p = PlayerCar();
      p.assignSpline(path,
          startDistance: (kTileSize - y).clamp(0.0, path.totalLength),
          worldOffset: Vector2.zero());
      p.position = p.splinePosition;
      return p;
    }

    test('in the ending lane the left indicator is forced on', () {
      final p = playerOn(tile.playerPaths[1], 600); // merge (ending) lane
      tile.updateNpcSensors(1 / 60, p, tile.npcs);
      expect(p.forceLeftIndicator, isTrue);
    });

    test('in the through lane there is no forced signal ("just go")', () {
      final p = playerOn(tile.playerPaths[0], 600); // through lane
      tile.updateNpcSensors(1 / 60, p, tile.npcs);
      expect(p.forceLeftIndicator, isFalse);
    });

    test('the unsafe-merge fault is armed while merging and DISARMS past the '
        'pinch (no late fault that reads as a later tile)', () {
      final graded =
          LaneTransitionTile(merging: true, scenario: MergeScenario())
            ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final sc = graded.scenario as MergeScenario;

      // Mid-merge (in the ending lane, before the pinch): armed.
      final merging = playerOn(graded.playerPaths[1], 600);
      graded.updateNpcSensors(1 / 60, merging, graded.npcs);
      expect(sc.playerIsMerging, isTrue);

      // Past the pinch (still on the merge spline, but merged in): disarmed —
      // a cut-off here must NOT fail the merge.
      final merged = playerOn(graded.playerPaths[1], 150); // below _taperEndY
      graded.updateNpcSensors(1 / 60, merged, graded.npcs);
      expect(sc.playerIsMerging, isFalse);
      sc.onDriverReaction();
      expect(sc.result.status, isNot(ScenarioStatus.failed),
          reason: 'a bump after the merge is complete is not an unsafe merge');
    });
  });
}
