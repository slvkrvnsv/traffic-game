import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/cars/npc_car.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';

/// Blinkers are MANUAL now — there is no automatic / curvature signalling for
/// the player. Two halves, locked in here:
///   1. [InputState.turnSignal] is the state machine the HUD blinker buttons
///      drive (arm a side, tap to clear, the two sides mutually exclusive).
///   2. [PlayerCar] mirrors that field onto its indicators every frame.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    // A lane-change commit fires a haptic; stub the platform channel so a bare
    // update() can never trip a MissingPluginException.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  setUp(InputState.instance.reset);
  tearDown(InputState.instance.reset);

  PlayerCar carOnAStraight() {
    final lane = Spline([Vector2(0, 1000), Vector2(0, 500), Vector2(0, 0)]);
    final p = PlayerCar();
    p.assignSpline(lane, worldOffset: Vector2.zero());
    p.setLaneOptions([lane], Vector2.zero(), 0.0, allowLaneChange: true);
    p.position = p.splinePosition;
    return p;
  }

  group('InputState.toggleSignal — the manual blinker state machine', () {
    test('starts off', () {
      expect(InputState.instance.turnSignal, 0);
    });

    test('a tap arms that side; tapping the same side again clears it', () {
      final input = InputState.instance;
      input.toggleSignal(-1);
      expect(input.turnSignal, -1);
      input.toggleSignal(-1);
      expect(input.turnSignal, 0);
    });

    test('arming one side cancels the other (always mutually exclusive)', () {
      final input = InputState.instance;
      input.toggleSignal(-1);
      input.toggleSignal(1);
      expect(input.turnSignal, 1, reason: 'flicking right cancels the armed left');
    });

    test('reset() clears an armed blinker', () {
      InputState.instance.toggleSignal(1);
      InputState.instance.reset();
      expect(InputState.instance.turnSignal, 0);
    });

    test('a real toggle notifies listeners (the HUD repaints)', () {
      final input = InputState.instance;
      var notes = 0;
      void listener() => notes++;
      input.addListener(listener);
      addTearDown(() => input.removeListener(listener));

      input.toggleSignal(-1); // off  -> left
      input.toggleSignal(-1); // left -> off
      expect(notes, 2, reason: 'arm + clear = two notifications');
    });
  });

  group('PlayerCar mirrors the manual blinker onto its indicators', () {
    test('nothing armed → both indicators dark', () {
      final p = carOnAStraight();
      p.update(1 / 60);
      expect(p.leftIndicatorVisible, isFalse);
      expect(p.rightIndicatorVisible, isFalse);
    });

    test('left armed → only the left indicator lights', () {
      final p = carOnAStraight();
      InputState.instance.toggleSignal(-1);
      p.update(1 / 60);
      expect(p.leftIndicatorVisible, isTrue);
      expect(p.rightIndicatorVisible, isFalse);
    });

    test('right armed → only the right indicator lights', () {
      final p = carOnAStraight();
      InputState.instance.toggleSignal(1);
      p.update(1 / 60);
      expect(p.rightIndicatorVisible, isTrue);
      expect(p.leftIndicatorVisible, isFalse);
    });

    test('clearing the blinker drops the indicator again', () {
      final p = carOnAStraight();
      InputState.instance.toggleSignal(-1);
      p.update(1 / 60);
      expect(p.leftIndicatorVisible, isTrue);
      InputState.instance.toggleSignal(-1); // tap the lit side back off
      p.update(1 / 60);
      expect(p.leftIndicatorVisible, isFalse);
    });
  });

  group('Manual blinker self-cancels after the turn (real intersection tile)', () {
    PlayerCar onApproach(IntersectionTile tile) {
      final p = PlayerCar();
      p.assignSpline(tile.playerPaths.first, worldOffset: Vector2.zero());
      p.setLaneOptions(tile.playerLaneMates(tile.playerPaths.first),
          Vector2.zero(), 0.0, allowLaneChange: true);
      p.position = p.splinePosition;
      InputState.instance.setGasLevel(1.0);
      return p;
    }

    // Drive [p] up the through-spine, steering [steer] (−left/+right) from the
    // box mouth and committing the fork onto the turn branch the same way
    // TileManager does (cloned from intersection_turn_steer_test). Runs to the
    // end of the path. Returns true if, at some frame, the car was on a turn
    // branch with the blinker still armed — i.e. it stayed lit through the turn.
    bool driveTurn(PlayerCar p, IntersectionTile tile, double steer) {
      final spine = tile.playerPaths.first;
      var armedMidTurn = false;
      for (int i = 0; i < 4000; i++) {
        if (p.hasReachedEnd) break;
        p.speed = kmhToUnits(40);
        final local = tile.worldToLocal(p.position);
        InputState.instance.setLaneSteer(local.y < 710 ? steer : 0.0);
        p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
        p.update(1 / 60);
        tile.updateNpcSensors(1 / 60, p, const <NpcCar>[], const <Pedestrian>[]);
        final cur = p.spline!;
        if (identical(cur, spine)) {
          final commit = TileManager.branchToCommit(
              p, cur, tile.playerBranches(cur), p.leanSign);
          if (commit != null) {
            p.commitFork(commit.branch, tile.playerLaneMates(commit.branch),
                tile.position, tile.orientation,
                startDistance: commit.startDistance,
                haptic: TileBase.pathTurns(commit.branch));
          }
        }
        if (!identical(p.spline, spine) && InputState.instance.turnSignal != 0) {
          armedMidTurn = true;
        }
      }
      return armedMidTurn;
    }

    test('a hand-armed LEFT blinker stays lit through the turn, then clears', () {
      final tile = IntersectionTile(maneuver: Maneuver.left)
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final p = onApproach(tile);
      InputState.instance.toggleSignal(-1); // arm LEFT by hand
      expect(InputState.instance.turnSignal, -1);

      final stayedLit = driveTurn(p, tile, -200.0); // steer the left turn
      expect(stayedLit, isTrue, reason: 'lit the whole way through the turn');
      expect(InputState.instance.turnSignal, 0,
          reason: 'self-cancels once the road straightens past the turn');
    });

    test('armed but driven STRAIGHT through → never self-cancels', () {
      final tile = IntersectionTile(maneuver: Maneuver.left)
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final p = onApproach(tile);
      InputState.instance.toggleSignal(-1);

      driveTurn(p, tile, 0.0); // neutral finger → goes straight through
      expect(InputState.instance.turnSignal, -1,
          reason: 'no bend taken → nothing to self-cancel; stays the player\'s to clear');
    });

    test('a RIGHT blinker is NOT cleared by driving through a LEFT turn', () {
      final tile = IntersectionTile(maneuver: Maneuver.left)
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final p = onApproach(tile);
      InputState.instance.toggleSignal(1); // armed the WRONG way (right)

      driveTurn(p, tile, -200.0); // but steer the LEFT turn
      expect(InputState.instance.turnSignal, 1,
          reason: 'self-cancel only fires for a turn in the signalled direction');
    });

    // The 2-lane light intersection also turns via the universal fork (different,
    // slightly sharper geometry) — guard that the single enter threshold clears
    // there too, so self-cancel isn't silently dead on light-tile turns.
    test('also self-cancels on the 2-lane light tile (left from the inner lane)',
        () {
      final tile = IntersectionLightTile()
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final p = PlayerCar();
      p.assignSpline(tile.approach(inner: true), worldOffset: Vector2.zero());
      p.setLaneOptions(tile.playerLaneMates(tile.approach(inner: true)),
          Vector2.zero(), 0.0, allowLaneChange: true);
      p.position = p.splinePosition;
      InputState.instance.setGasLevel(1.0);
      InputState.instance.toggleSignal(-1); // arm LEFT by hand

      for (int i = 0; i < 4000; i++) {
        if (p.hasReachedEnd) break;
        p.speed = kmhToUnits(40);
        final local = tile.worldToLocal(p.position);
        InputState.instance.setLaneSteer(-200.0); // hold left into the turn
        p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
        p.update(1 / 60);
        final cur = p.spline!;
        final commit = TileManager.branchToCommit(
            p, cur, tile.playerBranches(cur), p.leanSign);
        if (commit != null) {
          p.commitFork(commit.branch, tile.playerLaneMates(commit.branch),
              Vector2.zero(), 0.0,
              startDistance: commit.startDistance,
              haptic: TileBase.pathTurns(commit.branch));
        }
      }
      expect(InputState.instance.turnSignal, 0,
          reason: 'the light-tile turn straightens out and clears the blinker too');
    });
  });

  group('Manual blinker self-cancels on a committed merge (the haptic-click moment)', () {
    IntersectionLightTile place() => IntersectionLightTile()
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);

    // Drive a real corridor merge — the SLIDE commit that fires the haptic — from
    // one spine to the other, holding [steer]. The lane-transition "Merge left"
    // runs this exact offset-cap-commit code (PlayerCar._updateLaneChange), so
    // this is the same path. Returns true once it lands on the target spine.
    bool driveMerge(IntersectionLightTile tile, bool fromInner, double steer) {
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
        p.setLaneChangeAllowed(
            tile.allowsLaneChangeAt(tile.worldToLocal(p.position)));
        p.update(1 / 60);
        if (identical(p.spline, target)) return true;
      }
      return false;
    }

    test('a RIGHT blinker clears the instant a rightward merge commits', () {
      final tile = place();
      InputState.instance.toggleSignal(1); // arm RIGHT
      final merged = driveMerge(tile, true, 200.0); // inner→outer = rightward
      expect(merged, isTrue, reason: 'the merge completes');
      expect(InputState.instance.turnSignal, 0,
          reason: 'the merge commit (haptic click) drops the matching blinker');
    });

    test('a wrong-way (LEFT) blinker survives a rightward merge', () {
      final tile = place();
      InputState.instance.toggleSignal(-1); // armed LEFT, but we merge RIGHT
      final merged = driveMerge(tile, true, 200.0);
      expect(merged, isTrue);
      expect(InputState.instance.turnSignal, -1,
          reason: 'only a blinker matching the merge direction self-cancels');
    });

    test('cancelSignalForCompletedManeuver clears only a same-direction blinker', () {
      final p = PlayerCar();
      InputState.instance.toggleSignal(-1); // armed LEFT
      p.cancelSignalForCompletedManeuver(1); // a RIGHT maneuver finished
      expect(InputState.instance.turnSignal, -1, reason: 'wrong direction → stays');
      p.cancelSignalForCompletedManeuver(-1); // the LEFT maneuver finished
      expect(InputState.instance.turnSignal, 0, reason: 'matching direction → cleared');
    });

    // The real "Merge left": the lane-transition tile's TAPERING merge, where the
    // two lanes converge to coincident at the pinch. This is the merge the player
    // actually drives — verify it self-cancels (the SLIDE commit can be suppressed
    // near the pinch, so this is the load-bearing case, not the corridor one).
    test('the tapering "Merge left" self-cancels a left blinker', () {
      final tile = LaneTransitionTile(merging: true)
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final mergeLane = tile.playerPaths[1]; // ending lane
      final p = PlayerCar();
      p.assignSpline(mergeLane,
          startDistance: (kTileSize - 800).clamp(0.0, mergeLane.totalLength),
          worldOffset: Vector2.zero());
      p.setLaneOptions(tile.playerLaneMates(mergeLane), Vector2.zero(), 0.0,
          allowLaneChange: tile.allowsLaneChange);
      p.position = p.splinePosition;
      p.speed = kmhToUnits(40);
      InputState.instance.setGasLevel(1.0);
      InputState.instance.toggleSignal(-1); // arm LEFT for the merge

      for (int i = 0; i < 1500 && !p.hasReachedEnd; i++) {
        final local = tile.worldToLocal(p.position);
        InputState.instance.setLaneSteer(-200.0); // hold left into the merge
        p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
        p.update(1 / 60);
        tile.updateNpcSensors(1 / 60, p, tile.npcs, const []);
      }
      expect(InputState.instance.turnSignal, 0,
          reason: 'driving the "Merge left" clears the left blinker '
              '(its tapering lane bends enough to trip the curvature self-cancel)');
    });
  });
}
