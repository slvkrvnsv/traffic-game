import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';

/// The lane-transition connector now rides the SAME universal SLIDE primitive as
/// every other multi-lane tile — the offset-cap-commit lane change driven by
/// [PlayerCar.setLaneOptions] / [PlayerCar.nearestOn], not a bespoke one-shot fork.
/// These tests pin that the connector's VARYING-separation lanes (a tapering
/// merge/widen lane that starts coincident and opens to a full width) are handled
/// by that one model: a drag where the lanes are a real width apart commits cleanly
/// and position-continuously; near the pinch (separation below the commit gate) a
/// drag leans but does NOT commit/thrash, and the merging lane's own geometry
/// delivers the car in. Steering is gated POSITIONALLY by the tile
/// ([TileBase.allowsLaneChangeAt]), which TileManager pushes every frame; these
/// tests mimic that push. The parallel-road cases guard the ordinary 2-lane road
/// against regressing through the same shared steering code.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Swallow the haptic platform call fired on a lane commit.
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(InputState.instance.reset);

  /// One stepped frame: push the tile's positional steering verdict (as
  /// TileManager.\_updatePlayerLaneChange does) then advance the car. The universal
  /// merge reads its targets straight from the car's lane options — there is no
  /// per-frame fork target to push anymore.
  void step(PlayerCar p, TileBase tile) {
    final local = tile.worldToLocal(p.position);
    p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
    p.update(1 / 60);
  }

  /// Drive [p] forward on [tile] with the wheel held hard ([steerPx], + = right)
  /// for [frames]. Reports whether it reached [target], the max per-frame world
  /// jump, and the nose (extraYaw) stability — max per-frame change and number
  /// of sign flips (a fork "wobble" is a nose that snaps/oscillates).
  ({bool committed, double maxJump, double maxYawStep, int yawFlips}) drive(
      PlayerCar p, TileBase tile, Spline target, int frames,
      {int steerPx = 200}) {
    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(steerPx.toDouble()); // past the deadzone
    double maxJump = 0, maxYawStep = 0, prevYaw = p.extraYaw;
    int yawFlips = 0, lastSign = 0;
    bool committed = false;
    var prev = p.position.clone();
    for (int i = 0; i < frames; i++) {
      step(p, tile);
      final jump = p.position.distanceTo(prev);
      if (jump > maxJump) maxJump = jump;
      prev = p.position.clone();
      final yawStep = (p.extraYaw - prevYaw).abs();
      if (yawStep > maxYawStep) maxYawStep = yawStep;
      prevYaw = p.extraYaw;
      final sign = p.extraYaw > 0.02 ? 1 : (p.extraYaw < -0.02 ? -1 : 0);
      if (sign != 0) {
        if (lastSign != 0 && sign != lastSign) yawFlips++;
        lastSign = sign;
      }
      if (identical(p.spline, target)) committed = true;
    }
    return (
      committed: committed,
      maxJump: maxJump,
      maxYawStep: maxYawStep,
      yawFlips: yawFlips
    );
  }

  test('widen: drag-right onto the opening lane commits via the universal slide '
      '— no jump, no nose wobble', () {
    final tile = LaneTransitionTile(merging: false)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final through = tile.playerPaths[0];
    final diverge = tile.playerPaths[1];

    final p = PlayerCar();
    // Start where the lanes are still COINCIDENT (sep≈0, y≈950) and step down as
    // the outer lane opens — the sep 0→full region where the old offset cap once
    // snapped ~31u and reset the nose every frame.
    p.assignSpline(through, startDistance: 250, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    final r = drive(p, tile, diverge, 200);
    expect(r.committed, isTrue,
        reason: 'a right drag should end up following the diverging lane once it '
            'has opened a commit-worth of separation');
    expect(r.maxJump, lessThan(10),
        reason: 'the commit is position-continuous (nearest-point) — no snap');
    expect(r.maxYawStep, lessThan(0.1),
        reason: 'no per-frame nose reset (the wobble)');
    expect(r.yawFlips, lessThanOrEqualTo(1),
        reason: 'the nose must not oscillate through the change');
    expect(p.lateralOffset.abs(), lessThan(6),
        reason: 'settles onto the new lane (one drag = one switch)');
  });

  test('merge: near the pinch a held drag leans but does NOT commit/thrash '
      '(the commit gate suppresses a switch where the lanes coincide)', () {
    // Below kMinLaneCommitSeparation the universal merge never commits, so a held
    // drag can't ping-pong between the near-coincident lanes — the wobble the
    // player felt before. (Past the gate, drag commits once; see the cases below.)
    final tile = LaneTransitionTile(merging: true)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final through = tile.playerPaths[0];

    final p = PlayerCar();
    p.assignSpline(through, startDistance: 775, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(200);
    int switches = 0;
    var prevSpline = p.spline;
    for (int i = 0; i < 120; i++) {
      step(p, tile);
      if (!identical(p.spline, prevSpline)) switches++;
      prevSpline = p.spline;
    }
    expect(switches, lessThanOrEqualTo(1),
        reason: 'one decisive switch at most, never a pinball between '
            'coincident lanes');
  });

  test('merge: drag-left where the lanes are still a real width apart commits '
      'onto the surviving lane — smooth, no wobble', () {
    // On the ending merge lane, while it is clearly its own lane (separation above
    // the commit gate). A left drag is the "merge left" maneuver — the universal
    // slide switches onto the surviving (inner) lane, position-continuous.
    final tile = LaneTransitionTile(merging: true)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final through = tile.playerPaths[0];
    final mergeLane = tile.playerPaths[1];

    final p = PlayerCar();
    p.assignSpline(mergeLane, startDistance: 450, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    final r = drive(p, tile, through, 160, steerPx: -200); // drag LEFT to merge in
    expect(r.committed, isTrue,
        reason: 'drag-left in the separated zone commits onto the surviving lane');
    expect(r.maxJump, lessThan(10), reason: 'position-continuous switch');
    expect(r.maxYawStep, lessThan(0.1), reason: 'no per-frame nose reset');
    expect(r.yawFlips, lessThanOrEqualTo(1), reason: 'no nose oscillation');
  });

  test('merge: a LATE drag-left in the pinch rides the converging lane in — no '
      'formal switch, the car is still delivered to the inner lane, smoothly', () {
    // Past the commit gate (separation < kMinLaneCommitSeparation) a left drag can
    // no longer formally switch splines. That is by design and benign: the merging
    // lane geometry itself converges to the inner lane (720→640), so the car ends
    // physically at the inner lane while staying on the merging spline. The visible
    // change from the old one-shot fork — no buzz/switch at the very pinch — is the
    // one feel difference of folding the connector onto the universal model.
    final tile = LaneTransitionTile(merging: true)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final through = tile.playerPaths[0];
    final mergeLane = tile.playerPaths[1];

    final p = PlayerCar();
    p.assignSpline(mergeLane, startDistance: 760, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(-200); // drag LEFT, late, in the pinch
    // Track the NOSE too, not just position: this zone (cap collapsing as the lanes
    // converge) is exactly what the deleted [blockOffset] guard protected against
    // nose wobble — and a "wheels cranked while the car tracks straight" twitch
    // barely moves the car, so maxJump alone would miss it. The property is now held
    // by the edge-settle + glide instead; assert it here, in its own zone.
    double maxJump = 0, maxYawStep = 0, prevYaw = p.extraYaw;
    int yawFlips = 0, lastSign = 0;
    var prev = p.position.clone();
    for (int i = 0; i < 360; i++) {
      step(p, tile);
      final jump = p.position.distanceTo(prev);
      if (jump > maxJump) maxJump = jump;
      prev = p.position.clone();
      final yawStep = (p.extraYaw - prevYaw).abs();
      if (yawStep > maxYawStep) maxYawStep = yawStep;
      prevYaw = p.extraYaw;
      final sign = p.extraYaw > 0.02 ? 1 : (p.extraYaw < -0.02 ? -1 : 0);
      if (sign != 0) {
        if (lastSign != 0 && sign != lastSign) yawFlips++;
        lastSign = sign;
      }
    }
    const innerX = 640.0, outerEntryX = 720.0;
    expect(identical(p.spline, through), isFalse,
        reason: 'no formal switch below the commit gate — rides the merging lane');
    expect((p.position.x - innerX).abs(), lessThan(12),
        reason: 'the converging geometry still delivers the car to the inner lane');
    expect((p.position.x - innerX).abs(), lessThan((p.position.x - outerEntryX).abs()),
        reason: 'ends at the inner lane, not stranded out at the old outer lane');
    expect(maxJump, lessThan(10), reason: 'the ride-in stays smooth, no snap');
    expect(maxYawStep, lessThan(0.1),
        reason: 'no per-frame nose reset in the pinch — the property the deleted '
            'blockOffset guard enforced, now held by the edge-settle/glide');
    expect(yawFlips, lessThanOrEqualTo(1),
        reason: 'the nose must not oscillate as the cap collapses toward the pinch');
  });

  test('coincident lanes disable steering — the car holds (self-centres) on '
      'its lane even with the wheel held over', () {
    // Near the merge pinch the two lanes are within kSteerEnableSeparation, so
    // the tile reports steering off; the car must settle onto the single lane.
    final tile = LaneTransitionTile(merging: true)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final through = tile.playerPaths[0];

    final p = PlayerCar();
    p.assignSpline(through, startDistance: 900, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(200); // wheel held hard right
    double maxAbsLateral = 0;
    for (int i = 0; i < 60; i++) {
      step(p, tile);
      maxAbsLateral = maxAbsLateral > p.lateralOffset.abs()
          ? maxAbsLateral
          : p.lateralOffset.abs();
    }
    expect(maxAbsLateral, lessThan(2.0),
        reason: 'steering disabled where the lanes coincide → no lean');
  });

  test('widen steering is on from the start (no positional gate)', () {
    final tile = LaneTransitionTile(merging: false)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    expect(tile.allowsLaneChangeAt(Vector2(640, 1150)), isTrue); // at the entry
    expect(tile.allowsLaneChangeAt(Vector2(640, 300)), isTrue); // deep in
  });

  test('a held finger commits ONE lane then drops control — the car settles on '
      'the new lane instead of edge-pulling past it', () {
    final tile = StraightTile()
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final inner = tile.playerPaths[0];
    final outer = tile.playerPaths[1];

    final p = PlayerCar();
    p.assignSpline(inner, startDistance: 100, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    final r = drive(p, tile, outer, 240); // wheel held the whole time
    expect(r.committed, isTrue);
    // Without consumption a held finger edge-pulls the rightmost lane (~32u);
    // with it the car self-centres on the lane it switched to.
    expect(p.lateralOffset.abs(), lessThan(6),
        reason: 'finger consumed after the commit → settles, not edge-pulled');
  });

  test('parallel 2-lane road still commits cleanly (no regression)', () {
    final tile = StraightTile()
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final inner = tile.playerPaths[0];
    final outer = tile.playerPaths[1];

    final p = PlayerCar();
    p.assignSpline(inner, startDistance: 200, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    final r = drive(p, tile, outer, 180);
    expect(r.committed, isTrue);
    // Parallel straight lanes → no parameterisation artifact, so the commit is
    // tightly continuous (only normal per-frame travel).
    expect(r.maxJump, lessThan(8));
  });
}
