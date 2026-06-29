import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_one_lane_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/definitions/start_tile.dart';

/// Regression for the "straight tile vanishes the moment I snap onto the turn"
/// pop. An intersection late-binds its exit: it flags [exitChanged] when the
/// player STEERS a turn at the box. TileManager USED to teleport the already-
/// streamed (and still-visible) straight corridor onto the turn ([_rePlaceAfter]),
/// so the tile mounted ahead for "straight" blinked out the instant the car
/// diverted. It now ORPHANS that corridor in place — it keeps rendering where it
/// is and culls only once off-screen — and streams a FRESH corridor down the real
/// exit ([_redirectCorridorAfter]).
///
/// This drives the REAL [TileManager] through a steered left and asserts the
/// straight tile stays put (north of the junction, unmoved) while new road
/// appears on the turn (west). Under the old teleport the straight tile would be
/// gone from the north — so this fails on the regression and passes on the fix.
/// The redirect lives in TileManager and is shared by both junctions, so driving
/// the 1-lane intersection covers the 2-lane light too.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    StraightTile.register();
    StraightOneLaneTile.register();
    LaneTransitionTile.register();
    IntersectionTile.register();
    IntersectionLightTile.register();
    StartTile.register();
  });
  tearDown(InputState.instance.reset);

  test('steering a turn orphans the straight corridor in place and streams a '
      'fresh one on the turn (no pop)', () {
    final player = PlayerCar();
    final peds = <Pedestrian>[];
    final ambient = <Pedestrian>[];
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: peds,
      ambientPedestrians: ambient,
      testMode: TileType.intersection4way, // every tile a 1-lane junction
      testManeuver: Maneuver.left, // commanded left (HUD); the player steers it
      rng: math.Random(7),
    );
    tm.bootstrap();
    InputState.instance.setGasLevel(1.0);

    // The junction the player opens on. Its north edge (orientation 0 → north is
    // -y) is the line a straight-ahead tile sits beyond.
    final junction = tm.activeTile!;
    final northEdgeY = junction.worldCenter.y - junction.size.y / 2;

    bool committed = false;
    for (int i = 0; i < 4000; i++) {
      player.speed = kmhToUnits(40); // moderate + pinned → clean commit zone
      tm.allNpcs.clear(); // no traffic → nothing stalls the run
      peds.clear();
      ambient.clear();
      final local = junction.worldToLocal(player.position);
      // Lean left only at the box mouth (y<710) — the natural late steer the game
      // produces; TileManager._checkPlayerBranch resolves the tap.
      InputState.instance.setLaneSteer(local.y < 710 ? -200.0 : 0.0);
      player.update(1 / 60);
      tm.update(1 / 60);
      // The junction's exit flips west the frame the turn commits and the corridor
      // is redirected — capture that frame and inspect the result.
      if ((junction.worldExitDirection - Vector2(-1, 0)).length < 0.01) {
        committed = true;
        break;
      }
    }

    expect(committed, isTrue,
        reason: 'the steered left must commit, flipping the junction exit west');

    // 1) The straight-ahead corridor is STILL there, north of the junction: the
    //    pop is gone. Under the old re-place it would have been teleported west,
    //    leaving nothing straight ahead.
    expect(tm.liveTiles.any((t) => t.worldCenter.y < northEdgeY - 100), isTrue,
        reason:
            'the straight tile must stay put (orphaned), not pop onto the turn');

    // 2) A fresh corridor now runs down the committed (west) exit, so there is
    //    road to drive on after the turn.
    expect(
        tm.liveTiles.any((t) => t.worldCenter.x < junction.worldCenter.x - 400),
        isTrue,
        reason: 'a fresh tile must be streamed down the turn exit');
  });
}
