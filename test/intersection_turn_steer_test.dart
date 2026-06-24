import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/cars/npc_car.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';

/// The 1-lane intersection now uses the UNIVERSAL spline-steering: the player drives
/// a continuous through-spine and STEERS the commanded turn at the box (a tap), the
/// same mechanism as the 2-lane light. The exit is late-bound — it follows where the
/// player actually steered ([exitChanged] re-places the downstream road). These drive
/// the real PlayerCar + tile and resolve taps exactly as TileManager._checkPlayerBranch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(InputState.instance.reset);

  IntersectionTile place(Maneuver m) => IntersectionTile(maneuver: m)
    ..place(worldPosition: Vector2.zero(), orientation: 0.0);

  /// Drive [p] up the through-spine, each frame steering [steer] (−left/+right) and
  /// resolving a turn tap as TileManager._checkPlayerBranch does. Also ticks the
  /// tile's sensors so the late-bound exit ([_committedExit]/[exitChanged]) tracks the
  /// steered spline. Stops once the player diverts off the through-spine. Returns the
  /// spline the player ends on (a turn branch if a tap fired, else the through-spine).
  Spline drive(PlayerCar p, IntersectionTile tile, double Function(double y) steerAt) {
    final spine = tile.playerPaths.first;
    for (int i = 0; i < 2500; i++) {
      if (p.hasReachedEnd) break;
      p.speed = kmhToUnits(40); // PIN the speed → deterministic, never grade-stopped
      final local = tile.worldToLocal(p.position);
      InputState.instance.setLaneSteer(steerAt(local.y));
      p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
      p.update(1 / 60);
      tile.updateNpcSensors(1 / 60, p, const <NpcCar>[], const <Pedestrian>[]);
      final cur = p.spline!;
      // Diverted onto a turn — but only AFTER the sensor tick above, so the tile has
      // seen the player on the branch and committed the late-bound exit.
      if (!identical(cur, spine)) break;
      final commit = TileManager.branchToCommit(
          p, cur, tile.playerBranches(cur), p.leanSign);
      if (commit != null) {
        p.commitFork(commit.branch, tile.playerLaneMates(commit.branch),
            tile.position, tile.orientation,
            startDistance: commit.startDistance,
            haptic: TileBase.pathTurns(commit.branch));
      }
    }
    return p.spline!;
  }

  PlayerCar onApproach(IntersectionTile tile) {
    final p = PlayerCar();
    p.assignSpline(tile.playerPaths.first, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerLaneMates(tile.playerPaths.first), Vector2.zero(),
        0.0, allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);
    InputState.instance.setGasLevel(1.0);
    return p;
  }

  for (final m in [Maneuver.left, Maneuver.right]) {
    test('steering into the $m tap takes the $m turn and rotates the exit', () {
      final tile = place(m);
      // Fresh: late-bound exit is straight until the player steers the turn.
      expect(tile.worldExitDirection, Vector2(0, -1));

      final p = onApproach(tile);
      final steer = m == Maneuver.left ? -200.0 : 200.0; // lean toward the turn
      // LEAN LATE — only once the car has reached the intersection mouth (y<710,
      // well past the tap point at y=760/720). This is the NATURAL flow the real
      // game produces — and exactly the flow the old single-point tap FAILED,
      // because the tap was consumed during the approach before you steered.
      final end = drive(p, tile, (y) => y < 710 ? steer : 0.0);

      expect(end, same(tile.turnBranch(m)),
          reason: 'steering at the box (not from the start) still takes the $m turn');
      // The exit committed to the steered turn → downstream road must re-place.
      expect(tile.exitChanged, isTrue,
          reason: 'a steered turn flags exitChanged so the manager re-places the exit');
      final dir = m == Maneuver.left ? Vector2(-1, 0) : Vector2(1, 0);
      expect(tile.worldExitDirection, dir, reason: 'exit now points $m');
    });
  }

  test('no lean → stays straight through (miss = straight), exit unchanged', () {
    final tile = place(Maneuver.left); // commanded left, but the player never steers
    final p = onApproach(tile);
    final end = drive(p, tile, (_) => 0.0); // neutral the whole way

    expect(end, same(tile.playerPaths.first),
        reason: 'a neutral finger never diverts — the player goes straight');
    expect(tile.worldExitDirection, Vector2(0, -1),
        reason: 'miss = straight: the exit stays north when the turn is not steered');
  });
}
