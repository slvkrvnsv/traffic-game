import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/cars/npc_car.dart';
import 'package:traffic_game/cars/car_variants.dart';
import 'package:traffic_game/core/game_bus.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/feedback/driver_reaction.dart';
import 'package:traffic_game/feedback/driver_reaction_detector.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';

/// The cross-seam carry bug: through-traffic from the tile behind the player can
/// be carried onto the tile the player is now on. Without an occupancy check it
/// lands ON TOP of a car already queued at the new tile's entry (the visible "two
/// cars in one spot" / rear-end-the-player bug). The fix is PREVENTION — gate the
/// carry on `TileManager.seamSlotBlocked` — and a re-baseline so a teleported
/// follower can't fire a phantom "you cut me off" cut-off bubble.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    StraightTile.register();
  });

  group('seamSlotBlocked (cross-seam carry occupancy gate)', () {
    final origin = Vector2.zero();
    final heading = Vector2(1, 0); // travelling +x

    test('a car right at the entry blocks the carry', () {
      expect(TileManager.seamSlotBlocked(origin, heading, Vector2(15, 0)), isTrue);
      expect(TileManager.seamSlotBlocked(origin, heading, Vector2.zero()), isTrue,
          reason: 'a car directly on the entry (overlap) is blocked');
    });

    test('a car far enough ahead leaves room to queue (not blocked)', () {
      // > kCarLength + kNpcStandingGap (52 + 34 = 86) ahead.
      expect(TileManager.seamSlotBlocked(origin, heading, Vector2(100, 0)), isFalse);
    });

    test('a car behind the seam is irrelevant (not blocked)', () {
      expect(TileManager.seamSlotBlocked(origin, heading, Vector2(-40, 0)), isFalse);
    });

    test('a car in the adjacent lane is irrelevant (not blocked)', () {
      // ~one lane over (lateral 80 > kCarWidth*1.5 = 42).
      expect(TileManager.seamSlotBlocked(origin, heading, Vector2(10, 80)), isFalse);
    });
  });

  // Symptom 1's "warning" half: a follower carried across a seam appears right
  // behind the player discontinuously. The cut-off detector must NOT read that
  // teleport as the player cutting it off (a "!" against a player who did
  // nothing). The detector re-baselines on a spline-identity change.
  test('a cross-seam carry (spline change) does not phantom-fire a cut-off',
      () async {
    Future<bool> runScenario({required bool carryWhenClose}) async {
      final player = PlayerCar();
      final tm = TileManager(
        playerCar: player,
        world: World(),
        pedestrians: <Pedestrian>[],
        ambientPedestrians: <Pedestrian>[],
        testMode: TileType.straight,
      );
      tm.bootstrap();
      tm.allNpcs.clear();

      final tile = tm.activeTile as StraightTile;
      final splineA = tile.npcPaths[2];
      final splineB = tile.npcPaths[3];
      final speed = kmhToUnits(40); // 200 u/s

      final npc = NpcCar(definition: CarVariants.all.first, profileSpeed: speed);
      npc.assignSpline(splineA,
          worldOffset: tile.position, worldAngle: tile.orientation);
      tm.allNpcs.add(npc);

      final detector = DriverReactionDetector(
          playerCar: player, tileManager: tm, world: World());

      bool fired = false;
      final sub = GameBus.instance.on<DriverReactionEvent>().listen((e) {
        if (e.reaction == DriverReaction.cutOff) fired = true;
      });

      // Bootstrap put the player on a lane spline, so its heading is the lane's
      // (not 0). Align the NPC to that heading and place the player [along]
      // ahead and [perp] ~one car-width off the lane axis, so it reads as a
      // fresh in-lane intrusion (not "settled") — what a real cut-off needs.
      final ang = player.splineAngle;
      final along = Vector2(math.cos(ang), math.sin(ang));
      final perp = Vector2(-math.sin(ang), math.cos(ang));
      void place(double ahead, {Spline? newNpcSpline}) {
        if (newNpcSpline != null) {
          npc.assignSpline(newNpcSpline,
              worldOffset: tile.position, worldAngle: tile.orientation);
        }
        npc.position = Vector2.zero();
        npc.angle = ang;
        npc.speed = speed;
        player.position = along * ahead + perp * 30;
        player.speed = speed;
      }

      place(400); // frame 1: first sight (re-baseline), far
      detector.update(1 / 60);
      place(400); // frame 2: stable, far → no forced brake
      detector.update(1 / 60);
      // frame 3: player close → forced brake. Optionally arrive via a carry.
      place(120, newNpcSpline: carryWhenClose ? splineB : null);
      detector.update(1 / 60);

      // GameBus is a broadcast stream — flush the microtask queue so the emitted
      // event reaches the listener before we read [fired].
      await Future<void>.delayed(Duration.zero);
      sub.cancel();
      return fired;
    }

    // Sanity: the forced-brake geometry DOES fire when the NPC stays on its lane.
    expect(await runScenario(carryWhenClose: false), isTrue,
        reason: 'the forced-brake geometry must fire a cut-off on a stable spline '
            '(otherwise the suppression test below is vacuous)');
    // The fix: the SAME geometry reached via a carry (spline change) is silent.
    expect(await runScenario(carryWhenClose: true), isFalse,
        reason: 'a carry-induced spline change re-baselines instead of blaming the '
            'player for a phantom cut-off it did not cause');
  });
}
