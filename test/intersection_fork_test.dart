import 'dart:math' as math;
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
/// TileManager._checkPlayerBranch does (each frame, [TileManager.branchToCommit] on the
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
    for (int i = 0; i < maxFrames; i++) {
      if (p.hasReachedEnd) break;
      if (stopWhen != null && stopWhen(p.spline!)) break;
      final local = tile.worldToLocal(p.position);
      InputState.instance.setLaneSteer(steerAt(local.y));
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

  test('skip the near turn (neutral through its reach), lean at the FAR tap → far turn',
      () {
    for (final inner in [true, false]) {
      final tile = place();
      final p = onApproach(tile, inner: inner);
      final m = inner ? Maneuver.left : Maneuver.right;
      final dir = inner ? -200.0 : 200.0; // lean toward the turn
      final spine = tile.approach(inner: inner);
      // With the commit ZONE, "skip the near turn" means staying NEUTRAL through its
      // whole reach (its lead-in + early arc), not just past its tap point — then lean
      // only as we reach the FAR tap, so the far turn is what fires. Stop the drive the
      // instant we divert (the still-held lean would otherwise merge between the exit
      // lanes and mask which turn we took).
      final farTapY = tile.farBranch(m: m).evaluate(0.0).y;
      final end = drive(p, tile, (y) => y < farTapY + 12 ? dir : 0.0,
          stopWhen: (cur) => !identical(cur, spine));
      expect(end, same(tile.farBranch(m: m)),
          reason: 'neutral through the near turn + lean at the far tap → far turn');
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

  test('after a RIGHT turn you can ALSO merge to the neighbouring exit lane', () {
    // The mirror of the left case — and the one that was DEAD: the right turn lanes are
    // staggered (exit y=940 vs sibling node y=900), so a "past the lane?" guard using the
    // sibling's north-facing START tangent read the player (abreast of its EAST straight)
    // as "before the start" and nulled the merge. Left only worked by a coincidence (its
    // exit y equalled the sibling's node y → zero projection).
    final tile = place();
    final p = onApproach(tile, inner: false);
    final nearRight = tile.branch(inner: false, m: Maneuver.right);
    drive(p, tile, (_) => 200, stopWhen: (cur) => identical(cur, nearRight));
    expect(p.spline, same(nearRight));

    // far-right is the neighbouring east-bound exit lane, to the NORTH (= left when
    // heading east) — drag left and we should slide onto it.
    final sibling = tile.farBranch(m: Maneuver.right);
    expect(tile.playerLaneMates(p.spline!), contains(sibling));
    var merged = false;
    drive(p, tile, (_) => -200, stopWhen: (cur) {
      if (identical(cur, sibling)) merged = true;
      return merged;
    });
    expect(merged, isTrue,
        reason: 'the right post-turn merge must work too (curved-lane projection fix)');
  });

  test('merge-then-turn: the carried offset GLIDES onto the turn, never slams', () {
    // The exact bug: slide inner->outer, then immediately take the right turn while
    // the merge offset is still large. At the turn's start its sibling exit lane
    // begins ~80u AHEAD, so the cap momentarily collapses to kIntentionLean — the
    // old per-frame clamp YANKED the ~30u carried offset to 12u in a single frame
    // (an ~18u sideways snap, "moving to the spline too quick"). Now the cap only
    // blocks outward growth, so the offset eases home at the physical crab rate.
    final tile = place();
    final p = PlayerCar();
    final outer = tile.approach(inner: false);
    final nearRight = tile.branch(inner: false, m: Maneuver.right);
    // Park on the outer lane just south of the right tap, carrying a fresh-merge
    // offset (slid in from the inner lane → sitting ~32u to its left).
    final tapDist = outer.distanceAtNearest(nearRight.evaluate(0));
    p.assignSpline(outer, worldOffset: Vector2.zero());
    p.setT((tapDist - 30) / outer.totalLength);
    p.lateralOffset = -32.0;
    p.setLaneOptions(tile.playerLaneMates(outer), Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;

    var prev = p.position.clone();
    var maxJump = 0.0;
    var tookTurn = false;
    for (int i = 0; i < 90 && !p.hasReachedEnd; i++) {
      p.speed = kmhToUnits(40); // PIN the speed → deterministic crab rate
      final local = tile.worldToLocal(p.position);
      InputState.instance.setLaneSteer(200); // hold right through the tap
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
      if (identical(p.spline, nearRight)) tookTurn = true;
      final a = p.angle;
      final perp = Vector2(-math.sin(a), math.cos(a));
      final lat = (p.position - prev).dot(perp).abs();
      if (i > 0) maxJump = math.max(maxJump, lat);
      prev = p.position.clone();
    }

    expect(tookTurn, isTrue, reason: 'held right → took the right turn');
    expect(maxJump, lessThan(4.0),
        reason: 'the carried merge offset must glide onto the turn spline at the '
            'crab rate, not get slammed to the lean cap in one frame');
  });
}
