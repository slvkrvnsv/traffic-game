import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/game_bus.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_config.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';

/// End-to-end through the REAL [TileManager] (the standalone fork tests drive the
/// player directly; this one runs the manager's per-frame `_checkPlayerBranch` →
/// `branchToCommit` → `commitFork` glue inside `tm.update`). It pins the rule the user
/// cares about: the turn is decided ONLY by the live finger as you CROSS the tap —
/// lift the wheel before the turn and you stay on the spine you entered (straight,
/// then hand off), regardless of any residual lean; hold it and you take the turn.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    IntersectionLightTile.register();
    IntersectionTile.register();
    LaneTransitionTile.register();
    // Pin the light tile to L1 so the turn-driving tests are deterministic (the
    // registry/manager builds tiles and can't inject a config per tile).
    IntersectionLightTile.debugConfigOverride = LaneConfig.l1;
  });
  tearDownAll(() => IntersectionLightTile.debugConfigOverride = null);
  tearDown(InputState.instance.reset);

  /// Bootstrap a forced-intersection world, drag LEFT, optionally lift the finger
  /// before the near-left tap, and return the outcome: a turn name if the player
  /// diverted, or 'straight' if they drove the whole entry spine and handed off.
  String driveAndForkBranch({required bool release}) {
    final player = PlayerCar();
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: <Pedestrian>[],
      ambientPedestrians: <Pedestrian>[],
      testMode: TileType.intersectionLight,
    );
    tm.bootstrap();
    player.speed = kmhToUnits(35);
    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(-200); // drag LEFT

    final tile = tm.activeTile as IntersectionLightTile;
    final entry = player.spline;
    // The turn branches of THIS tile, by outcome name (straight is no longer a spline
    // — it's staying on [entry]).
    final turns = <Spline, String>{
      tile.branch(inner: true, m: Maneuver.left): 'inner-left',
      tile.branch(inner: false, m: Maneuver.right): 'outer-right',
      tile.farBranch(m: Maneuver.left): 'far-left',
      tile.farBranch(m: Maneuver.right): 'far-right',
    };
    var released = false;
    for (int i = 0; i < 1500; i++) {
      final local = tile.worldToLocal(player.position);
      if (release && !released && local.y <= 1120) {
        InputState.instance.endLaneSteer(); // LIFT the finger before the tap
        released = true;
      }
      player.update(1 / 60);
      tm.update(1 / 60);
      final s = player.spline;
      if (s == null) continue;
      for (final t in turns.entries) {
        if (identical(s, t.key)) return t.value; // diverted onto a turn
      }
      // Stayed on the entry spine and handed off to the next tile → drove it straight.
      if (!identical(s, entry) && !turns.keys.any((t) => identical(s, t))) {
        return 'straight';
      }
    }
    return 'none';
  }

  test('lift the wheel before the tap → stay straight (real manager flow)', () {
    expect(driveAndForkBranch(release: true), contains('straight'));
  });

  test('hold the wheel left into the tap → take the left turn', () {
    expect(driveAndForkBranch(release: false), 'inner-left');
  });

  test('grade-at-clear fires through the REAL manager: straight from the inner '
      '(left-only) lane is a logged lane fault', () async {
    // Closes the end-to-end gap the unit tests can't reach: the player PHYSICALLY
    // clears the box, _gradeLaneDiscipline runs at that moment on the entry spline
    // (not after a silent hand-off → the `did == null` trapdoor), and it emits.
    // Pinned to L1, the inner lane is left-only, so driving STRAIGHT is a fault for
    // EVERY random command — wrong lane for a commanded straight/right, wrong
    // maneuver (the dodge) for a commanded left — so no command control is needed.
    final faults = <GameEvent>[];
    final sub = GameBus.instance.stream
        .where((e) =>
            e is WrongLaneEvent ||
            e is MissedTurnEvent ||
            e is WrongExitLaneEvent)
        .listen(faults.add);

    final player = PlayerCar();
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: <Pedestrian>[],
      ambientPedestrians: <Pedestrian>[],
      testMode: TileType.intersectionLight,
    );
    tm.bootstrap();
    InputState.instance.setGasLevel(1.0);
    final tile = tm.activeTile as IntersectionLightTile;
    for (int i = 0; i < 2000; i++) {
      player.speed = kmhToUnits(35); // pin → keeps moving straight through
      player.update(1 / 60);
      tm.update(1 / 60);
      // Past the box far edge (clear at local y < cy−half = 660) and then some.
      if (tile.worldToLocal(player.position).y < 560) break;
    }
    await Future<void>.delayed(Duration.zero); // drain the async broadcast bus
    await sub.cancel();

    expect(faults, isNotEmpty,
        reason: 'clearing the box straight from the left-only inner lane must be '
            'graded a lane fault — the full clear → grade → emit chain');
  });

  test('MERGE through the REAL manager: hold right from inner → onto outer, no jump',
      () {
    // The user's literal complaint was "merge is glitchy" — drive a real corridor
    // merge through tm.update() (so _checkPlayerBranch runs every frame WHILE the merge
    // is in progress) and assert it lands on the outer spine with no single-frame
    // lateral snap (the old seam dead-band slammed ~30u).
    final player = PlayerCar();
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: <Pedestrian>[],
      ambientPedestrians: <Pedestrian>[],
      testMode: TileType.intersectionLight,
    );
    tm.bootstrap();
    player.speed = kmhToUnits(35);
    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(200); // hold RIGHT (inner → outer)

    final tile = tm.activeTile as IntersectionLightTile;
    final outer = tile.approach(inner: false);
    var prev = player.position.clone();
    double maxJump = 0;
    var reachedOuter = false;
    for (int i = 0; i < 600; i++) {
      player.update(1 / 60);
      tm.update(1 / 60);
      // Perpendicular-to-heading step (robust whatever the heading), so a clamp snap
      // shows up regardless of where in the box it happens.
      final perp = Vector2(-math.sin(player.angle), math.cos(player.angle));
      final step = (player.position - prev).dot(perp).abs();
      if (step > maxJump) maxJump = step;
      prev = player.position.clone();
      if (identical(player.spline, outer)) {
        reachedOuter = true;
        break;
      }
    }
    expect(reachedOuter, isTrue, reason: 'the held-right merge reaches the outer spine');
    expect(maxJump, lessThan(4),
        reason: 'no seam dead-band snap through the real manager merge');
  });

  test('1-lane intersection: a LATE right steer at the box still turns (real manager)',
      () {
    // The exact reported regression, through the REAL tm.update → _checkPlayerBranch →
    // branchToCommit → commitFork (not a replicated helper — that one passed while the
    // game was 100% broken). Drive the 1-lane intersection and steer RIGHT only as the
    // car REACHES the box (the natural late lean). With the old single-point tap this
    // was impossible (the tap was consumed ~80u before the box); the commit ZONE fixes
    // it. Commanded maneuver is irrelevant — both turns are always offered.
    final player = PlayerCar();
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: <Pedestrian>[],
      ambientPedestrians: <Pedestrian>[],
      testMode: TileType.intersection4way,
    );
    tm.bootstrap();
    InputState.instance.setGasLevel(1.0);

    final tile = tm.activeTile as IntersectionTile;
    final rightTurn = tile.turnBranch(Maneuver.right);
    var leaned = false;
    var took = false;
    for (int i = 0; i < 1500; i++) {
      player.speed = kmhToUnits(30); // pin → always reaches the box, never grade-stopped
      final local = tile.worldToLocal(player.position);
      if (local.y < 710) {
        InputState.instance.setLaneSteer(200); // steer RIGHT, late, AT the box mouth
        leaned = true;
      }
      player.update(1 / 60);
      tm.update(1 / 60);
      if (identical(player.spline, rightTurn)) {
        took = true;
        break;
      }
    }
    expect(leaned, isTrue, reason: 'the car reached the box and steered');
    expect(took, isTrue,
        reason: 'a late right steer at the box takes the right turn through the real '
            'manager — the regression the user hit ("100% can not turn right")');
  });

  test('connector MERGE through the REAL manager: drag-left from the ending lane '
      'commits via the universal slide AND the merge grading clears', () {
    // The connector's bespoke one-shot fork is gone — it now rides the SAME
    // playerLaneMates → offset-merge wiring as every multi-lane tile. Prove it
    // through the REAL tm.update() (not the replicated step() helper in
    // lane_change_diverge_test, which hand-pushes the gate and can't exercise the
    // manager glue — exactly the kind of replicated test that once passed while the
    // game was broken). Put the player on the ending (outer) lane at the wide entry
    // as a seam hand-off from a 2-lane straight would, hold a left drag, and assert
    // the universal merge commits onto the inner (surviving) lane AND MergeScenario
    // clears (passed) once the player is in past the pinch.
    final player = PlayerCar();
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: <Pedestrian>[],
      ambientPedestrians: <Pedestrian>[],
      testMode: TileType.laneMerge,
    );
    tm.bootstrap();

    final tile = tm.activeTile as LaneTransitionTile;
    final inner = tile.playerPaths[0];
    final outer = tile.playerPaths[1];
    // Bootstrap drops the player on the inner lane; move them onto the ending
    // (outer) lane at the wide entry — where a hand-off from the outer lane of a
    // preceding 2-lane straight would leave them.
    player.assignSpline(outer,
        startDistance: 60,
        worldOffset: tile.position,
        worldAngle: tile.orientation);
    player.setLaneOptions(tile.playerLaneMates(outer), tile.position,
        tile.orientation, allowLaneChange: true);
    player.position = player.splinePosition;

    InputState.instance.setGasLevel(1.0);
    var committed = false;
    for (int i = 0; i < 3000; i++) {
      player.speed = kmhToUnits(30); // pin → always reaches the end of the taper
      InputState.instance.setLaneSteer(-200); // hold LEFT — merge in
      // Isolate the player-merge grading from any NPC cut-off path: NPCs spawn in
      // _tickRefill, which runs AFTER _updateNpcSensors (the grading), so clearing
      // at the top of the loop leaves the sensor tick with an empty NPC list.
      tm.allNpcs.clear();
      player.update(1 / 60);
      tm.update(1 / 60);
      if (identical(player.spline, inner)) committed = true;
      if (tile.scenario.result.status == ScenarioStatus.passed) break;
    }
    expect(committed, isTrue,
        reason: 'the universal slide commits the merge onto the inner lane through '
            'the real manager (playerLaneMates → offset-cap-commit)');
    expect(tile.scenario.result.status, ScenarioStatus.passed,
        reason: 'the merge grading clears once the player has merged in and passed '
            'the pinch — the connector is graded on the universal path');
  });
}
