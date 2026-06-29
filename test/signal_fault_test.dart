import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/game_bus.dart';
import 'package:traffic_game/cars/npc_car.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/rules/exam_error.dart';
import 'package:traffic_game/rules/exam_error_log.dart';
import 'package:traffic_game/rules/exam_error_recorder.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_config.dart';

/// Two GLOBAL exam faults (no per-tile grading): driving a commanded TURN or a
/// LANE CHANGE without the matching blinker armed. Detected at the universal
/// commit points in PlayerCar, emitted on the GameBus, recorded by the same
/// path as the cut-off fault. The load-bearing checks are the false positives —
/// a correctly-signalled maneuver must record ZERO faults (proves the grade
/// reads the blinker before the self-cancel clears it).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  setUp(InputState.instance.reset);
  tearDown(InputState.instance.reset);

  // A live recorder on the current bus generation; torn down so its bus
  // subscription doesn't leak onto the singleton. Mirrors gamebus_generation_test.
  ExamErrorRecorder mountRecorder() {
    final r = ExamErrorRecorder(
      tileManager: TileManager(
        playerCar: PlayerCar(),
        world: World(),
        pedestrians: const [],
        ambientPedestrians: const [],
      ),
      log: ExamErrorLog.instance,
    )..onMount();
    addTearDown(r.onRemove);
    return r;
  }

  List<ExamError> faultsOfType(ExamErrorType t) =>
      ExamErrorLog.instance.currentRunErrors.where((e) => e.type == t).toList();

  // --- Turn drive (1-lane intersection), cloned from intersection_turn_steer ---
  IntersectionTile placeTurn(Maneuver m) => IntersectionTile(maneuver: m)
    ..place(worldPosition: Vector2.zero(), orientation: 0.0);

  PlayerCar onApproachTurn(IntersectionTile tile) {
    final p = PlayerCar();
    p.assignSpline(tile.playerPaths.first, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerLaneMates(tile.playerPaths.first),
        Vector2.zero(), 0.0, allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);
    InputState.instance.setGasLevel(1.0);
    return p;
  }

  void driveTurn(PlayerCar p, IntersectionTile tile, double Function(double y) steerAt) {
    final spine = tile.playerPaths.first;
    for (int i = 0; i < 2500; i++) {
      if (p.hasReachedEnd) break;
      p.speed = kmhToUnits(40);
      final local = tile.worldToLocal(p.position);
      InputState.instance.setLaneSteer(steerAt(local.y));
      p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
      p.update(1 / 60);
      tile.updateNpcSensors(1 / 60, p, const <NpcCar>[], const <Pedestrian>[]);
      final cur = p.spline!;
      if (!identical(cur, spine)) break; // diverted onto the turn branch
      final commit = TileManager.branchToCommit(
          p, cur, tile.playerBranches(cur), p.leanSign);
      if (commit != null) {
        p.commitFork(commit.branch, tile.playerLaneMates(commit.branch),
            tile.position, tile.orientation,
            startDistance: commit.startDistance,
            haptic: TileBase.pathTurns(commit.branch));
      }
    }
  }

  // --- Lane-change drive (corridor merge), cloned from corridor_merge_test ---
  IntersectionLightTile placeLight() => IntersectionLightTile(config: LaneConfig.l1)
    ..place(worldPosition: Vector2.zero(), orientation: 0.0);

  void driveCorridorMerge(IntersectionLightTile tile, bool fromInner, double steer) {
    final p = PlayerCar();
    p.assignSpline(tile.approach(inner: fromInner),
        startDistance: 1640 - 1010, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerLaneMates(tile.approach(inner: fromInner)),
        Vector2.zero(), 0.0, allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);
    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(steer);
    final target = tile.approach(inner: !fromInner);
    for (int i = 0; i < 600 && !p.hasReachedEnd; i++) {
      p.setLaneChangeAllowed(tile.allowsLaneChangeAt(tile.worldToLocal(p.position)));
      p.update(1 / 60);
      if (identical(p.spline, target)) break;
    }
  }

  group('Turn without signalling', () {
    test('an UNSIGNALLED left turn records exactly one turn fault', () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      final tile = placeTurn(Maneuver.left);
      final p = onApproachTurn(tile);
      driveTurn(p, tile, (y) => y < 710 ? -200.0 : 0.0); // steer the turn, no blinker
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.turnWithoutSignal), hasLength(1));
      expect(faultsOfType(ExamErrorType.laneChangeWithoutSignal), isEmpty);
      expect(ExamErrorType.turnWithoutSignal.label, 'Turned without signalling');
    });

    test('a correctly-signalled left turn records NO fault (false-positive guard)',
        () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      final tile = placeTurn(Maneuver.left);
      final p = onApproachTurn(tile);
      InputState.instance.toggleSignal(-1); // arm LEFT before the turn
      driveTurn(p, tile, (y) => y < 710 ? -200.0 : 0.0);
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.turnWithoutSignal), isEmpty,
          reason: 'signalled the turn → no fault');
    });

    test('going STRAIGHT through (no turn taken) records no turn fault', () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      final tile = placeTurn(Maneuver.left); // commanded left, but never steered
      final p = onApproachTurn(tile);
      driveTurn(p, tile, (_) => 0.0); // neutral the whole way → stays straight
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.turnWithoutSignal), isEmpty,
          reason: 'no turn was committed → nothing to grade');
    });

    test('the WRONG-way blinker still faults a left turn (direction-specific)',
        () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      final tile = placeTurn(Maneuver.left);
      final p = onApproachTurn(tile);
      InputState.instance.toggleSignal(1); // armed RIGHT for a LEFT turn
      driveTurn(p, tile, (y) => y < 710 ? -200.0 : 0.0);
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.turnWithoutSignal), hasLength(1),
          reason: 'a right blinker does not signal a left turn');
    });

    test('an UNSIGNALLED right turn also faults (right-turn sign convention)',
        () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      final tile = placeTurn(Maneuver.right);
      final p = onApproachTurn(tile);
      driveTurn(p, tile, (y) => y < 710 ? 200.0 : 0.0); // steer right, no blinker
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.turnWithoutSignal), hasLength(1));
    });

    test('a correctly-signalled right turn records NO fault (false-positive guard)',
        () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      final tile = placeTurn(Maneuver.right);
      final p = onApproachTurn(tile);
      InputState.instance.toggleSignal(1); // arm RIGHT before the right turn
      driveTurn(p, tile, (y) => y < 710 ? 200.0 : 0.0);
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.turnWithoutSignal), isEmpty,
          reason: 'signalled the right turn → no fault (sign convention holds)');
    });
  });

  group('Lane change without signalling', () {
    test('an UNSIGNALLED lane change records exactly one lane-change fault',
        () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      driveCorridorMerge(placeLight(), true, 200.0); // rightward, no blinker
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.laneChangeWithoutSignal), hasLength(1));
      expect(faultsOfType(ExamErrorType.turnWithoutSignal), isEmpty);
      expect(ExamErrorType.laneChangeWithoutSignal.label,
          'Changed lanes without signalling');
    });

    test('a correctly-signalled lane change records NO fault (false-positive guard)',
        () async {
      GameBus.instance.newGeneration();
      mountRecorder();
      InputState.instance.toggleSignal(1); // arm RIGHT before the rightward move
      driveCorridorMerge(placeLight(), true, 200.0);
      await pumpEventQueue();

      expect(faultsOfType(ExamErrorType.laneChangeWithoutSignal), isEmpty,
          reason: 'signalled the lane change → no fault');
    });
  });
}
