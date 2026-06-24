import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';

/// End-to-end of the UNIVERSAL STEERING on the light intersection: drive a player up
/// a continuous through-lane SPINE, and resolve TURN TAPS exactly as
/// TileManager._checkPlayerBranch does (each frame, [TileManager.branchToTake] on the
/// current spline; a crossed tap on the lean side diverts onto that turn). The spine is
/// ONE whole spline, so the parallel-lane SLIDE (merge) is just the player's ordinary
/// offset lane-change — no chopped stubs, no seam. This is the frame-stepped wiring the
/// piece-wise tile/manager unit tests miss.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(InputState.instance.reset);

  IntersectionLightTile place() => IntersectionLightTile()
    ..place(worldPosition: Vector2.zero(), orientation: 0.0);

  PlayerCar onApproach(IntersectionLightTile tile, {required bool inner}) {
    final p = PlayerCar();
    p.assignSpline(tile.approach(inner: inner), worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerLaneMates(tile.approach(inner: inner)),
        Vector2.zero(), 0.0, allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);
    InputState.instance.setGasLevel(1.0);
    return p;
  }

  /// Drive [p] until it reaches a spline end (or [stopWhen]/[maxFrames]), each frame
  /// setting the lane-steer from [steerAt] (given the player's local y) and resolving
  /// turn taps EXACTLY as TileManager._checkPlayerBranch does. Returns the spline the
  /// player ends on — a turn branch if a tap was taken, else the through spine (=
  /// straight). The merge (SLIDE between the parallel spines) runs inside p.update().
  Spline drive(
    PlayerCar p,
    IntersectionLightTile tile,
    double Function(double y) steerAt, {
    int maxFrames = 2500,
    bool Function(Spline cur)? stopWhen,
  }) {
    Spline? branchSpline;
    double baseDist = 0.0;
    for (int i = 0; i < maxFrames; i++) {
      if (p.hasReachedEnd) break;
      if (stopWhen != null && stopWhen(p.spline!)) break;
      final local = tile.worldToLocal(p.position);
      InputState.instance.setLaneSteer(steerAt(local.y));
      p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
      p.update(1 / 60);
      final cur = p.spline!;
      if (!identical(cur, branchSpline)) {
        branchSpline = cur;
        baseDist = p.distanceTravelled;
        continue; // need two samples to detect a crossing
      }
      final from = baseDist;
      final to = p.distanceTravelled;
      baseDist = to;
      final chosen = TileManager.branchToTake(
          cur, tile.playerBranches(cur), from, to, p.leanSign);
      if (chosen != null) {
        p.commitFork(chosen, tile.playerLaneMates(chosen), Vector2.zero(), 0.0,
            haptic: TileBase.pathTurns(chosen));
      }
    }
    return p.spline!;
  }

  test('hold LEFT up the inner spine → takes the left turn, seamlessly', () {
    final tile = place();
    final p = onApproach(tile, inner: true);
    final end = drive(p, tile, (_) => -200); // hold left the whole way

    expect(end, same(tile.branch(inner: true, m: Maneuver.left)));
    expect(p.splineCentrePosition.x, lessThan(60), reason: 'left turn exits west');
  });

  test('hold RIGHT up the outer spine → takes the right turn, seamlessly', () {
    final tile = place();
    final p = onApproach(tile, inner: false);
    final end = drive(p, tile, (_) => 200); // hold right

    expect(end, same(tile.branch(inner: false, m: Maneuver.right)));
    expect(p.splineCentrePosition.x, greaterThan(1140), reason: 'right turn exits east');
  });

  test('release before the tap → goes straight (no residual-lean turn)', () {
    final tile = place();
    final p = onApproach(tile, inner: true);
    // Lean left briefly, then RELEASE well before the near-left tap (y=860). The lean
    // eases back lazily, but leanSign reads the (now lifted) finger → neutral → no
    // divert → stays on the spine all the way to the north exit.
    InputState.instance.setLaneSteer(-200);
    for (int i = 0; i < 12; i++) {
      p.update(1 / 60);
    }
    InputState.instance.setLaneSteer(0);
    final end = drive(p, tile, (_) => 0);

    expect(end, same(tile.branch(inner: true, m: Maneuver.straight)),
        reason: 'a released finger stays on the spine even with the lean still easing');
  });

  test('no drag → straight through (stays on the spine)', () {
    final tile = place();
    final p = onApproach(tile, inner: false);
    final end = drive(p, tile, (_) => 0);
    expect(end, same(tile.branch(inner: false, m: Maneuver.straight)));
  });

  test('MERGE-FIRST then turn: start inner, hold right → merge to outer, take right', () {
    final tile = place();
    final p = onApproach(tile, inner: true);
    // Hold right the whole way: on the inner spine the only mergeable lane is the outer
    // (the turns there are LEFT, so a right lean never diverts) → it MERGES inner→outer;
    // then on the outer spine the held right takes the right turn. "Merge first, then
    // turn" — you can only turn right after merging out.
    final end = drive(p, tile, (_) => 200);
    expect(end, same(tile.branch(inner: false, m: Maneuver.right)),
        reason: 'merged to the outer spine, then took its right turn');
  });

  test('skip the near tap, lean at the deeper one → the FAR (other-lane) turn', () {
    for (final inner in [true, false]) {
      final tile = place();
      final p = onApproach(tile, inner: inner);
      final dir = inner ? -200.0 : 200.0; // lean toward the turn
      final nearTapY = inner ? 860.0 : 980.0; // skip THIS tap (stay neutral here)
      final spine = tile.approach(inner: inner);
      // Only lean AFTER passing the near tap → the second (deep) tap takes it. Stop the
      // drive the instant we divert onto a turn — otherwise the still-held lean would
      // merge us between the two exit lanes and mask which tap fired.
      final end = drive(p, tile, (y) => y < nearTapY - 6 ? dir : 0.0,
          stopWhen: (cur) => !identical(cur, spine));
      expect(end, same(tile.farBranch(m: inner ? Maneuver.left : Maneuver.right)),
          reason: 'neutral at the near tap + lean at the far tap → far turn');
      InputState.instance.reset();
    }
  });

  test('after a LEFT turn you can still merge to the neighbouring exit lane', () {
    final tile = place();
    final p = onApproach(tile, inner: true);
    final nearLeft = tile.branch(inner: true, m: Maneuver.left);
    // Hold left → divert onto the left turn; stop the drive the moment we're on it.
    drive(p, tile, (_) => -200, stopWhen: (cur) => identical(cur, nearLeft));
    expect(p.spline, same(nearLeft));

    // On the left turn now. The magnetic SLIDE must keep working (the spline is king):
    // far-left is the neighbouring west-bound exit lane — drag right and we switch onto
    // it. (Taps are inert on a turn branch, so this is a pure merge.)
    final sibling = tile.farBranch(m: Maneuver.left);
    expect(tile.playerLaneMates(p.spline!), contains(sibling));
    var merged = false;
    drive(p, tile, (_) => 200, stopWhen: (cur) {
      if (identical(cur, sibling)) merged = true;
      return merged;
    });
    expect(merged, isTrue,
        reason: 'the magnetic merge works AFTER a turn, not only on a straight spine');
  });

  test('CORRIDOR: starting deep in the box on the inner spine, drag right still merges',
      () {
    final tile = place();
    final p = PlayerCar();
    // Start ~y=960 — IN the box, past where the outer lane's near tap (y=980) already
    // sits. The OLD chopped lanes went blind here (seam dead-band → jump). With one
    // whole spine the merge sees a continuous neighbour the whole way.
    p.assignSpline(tile.approach(inner: true),
        startDistance: 680, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerLaneMates(tile.approach(inner: true)), Vector2.zero(),
        0.0, allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(35);
    InputState.instance.setGasLevel(1.0);

    final end = drive(p, tile, (_) => 200); // drag right
    // Ended on an OUTER-lane outcome (its through spine or a right turn) → the merge
    // worked even though the outer lane had already passed its near tap.
    final outer = [
      tile.branch(inner: false, m: Maneuver.straight), // outerThrough
      tile.branch(inner: false, m: Maneuver.right), // nearRight
      tile.farBranch(m: Maneuver.right), // farRight
    ];
    expect(outer.any((s) => identical(s, end)), isTrue,
        reason: 'a tap on the outer spine must not switch off merging into it');
  });

  test('two parallel WHOLE spines → merge works anywhere along the corridor (no jump)',
      () {
    final tile = place();
    final p = onApproach(tile, inner: true);
    // Drive straight for a stretch (no drag) — stays on the inner spine.
    drive(p, tile, (_) => 0, maxFrames: 30);
    expect(p.spline, same(tile.approach(inner: true)));

    // Now drag RIGHT → SLIDE onto the outer spine. Both are whole, parallel splines,
    // so this is an ordinary lane change with no seam dead-band.
    final outer = tile.approach(inner: false);
    var merged = false;
    drive(p, tile, (_) => 200, stopWhen: (cur) {
      if (identical(cur, outer)) merged = true;
      return merged;
    });
    expect(merged, isTrue, reason: 'two parallel whole spines → merge must work');
  });
}
