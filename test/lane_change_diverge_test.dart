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

/// Lane-change must work for a lane whose separation VARIES (a widening tile's
/// diverging lane starts coincident with the through lane and opens gradually),
/// not just fixed-width parallel lanes — and the commit must stay
/// position-continuous. Steering is gated POSITIONALLY by the tile
/// (TileBase.allowsLaneChangeAt), which TileManager pushes every frame; these
/// tests mimic that push. This is the frame-stepped, input-driven path that
/// component tests miss. The parallel-road case guards against regressing the
/// normal road and the merge tile (same shared steering code).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Swallow the haptic platform call fired on a lane commit.
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(InputState.instance.reset);

  /// One stepped frame: push the tile's positional steering verdict + fork
  /// targets (as TileManager does) then advance the car.
  void step(PlayerCar p, TileBase tile) {
    final local = tile.worldToLocal(p.position);
    p.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
    p.setForkTargets(
        tile.splineSteerTargetAt(local, -1), tile.splineSteerTargetAt(local, 1));
    p.update(1 / 60);
  }

  /// Drive [p] forward on [tile] with the wheel held hard ([steerPx], + = right)
  /// for [frames]. Reports whether it reached [target], the max per-frame world
  /// jump, and the nose (extraYaw) stability — max per-frame change and number
  /// of sign flips (the fork "wobble" is a nose that snaps/oscillates).
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

  test('widen FORK: drag-right through the splitting splines spline-steers onto '
      'the new lane — no jump, no nose wobble', () {
    final tile = LaneTransitionTile(merging: false)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final through = tile.playerPaths[0];
    final diverge = tile.playerPaths[1];

    final p = PlayerCar();
    // Start where the lanes are still COINCIDENT (sep≈0, y≈950) and step down
    // through the fork — this is the sep 0→1 region where the old offset cap
    // snapped ~31u and reset the nose every frame.
    p.assignSpline(through, startDistance: 250, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    final r = drive(p, tile, diverge, 200);
    expect(r.committed, isTrue,
        reason: 'a right drag should end up following the diverging lane');
    expect(r.maxJump, lessThan(10),
        reason: 'the spline switch is position-continuous — no snap');
    expect(r.maxYawStep, lessThan(0.1),
        reason: 'no per-frame nose reset (the wobble)');
    expect(r.yawFlips, lessThanOrEqualTo(1),
        reason: 'the nose must not oscillate through the fork');
    expect(p.lateralOffset.abs(), lessThan(6),
        reason: 'settles onto the new lane (one drag = one switch)');
  });

  test('merge fork: a held drag switches at most ONCE — no ping-pong / pinball',
      () {
    // The merge end is also a fork (lanes converged), so it spline-steers too.
    // A held drag should produce one clean switch, never the rapid back-and-forth
    // the player felt before.
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
        reason: 'one decisive switch, never a pinball between coincident lanes');
  });

  test('merge FORK: drag-left near the merge point spline-steers onto the '
      'surviving lane — smooth, no wobble (same approach as the widen)', () {
    final tile = LaneTransitionTile(merging: true)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final through = tile.playerPaths[0];
    final mergeLane = tile.playerPaths[1];

    final p = PlayerCar();
    // On the ending merge lane, in the converging fork (lanes < a lane-width
    // apart, just before they coincide).
    p.assignSpline(mergeLane, startDistance: 750, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerPaths, Vector2.zero(), 0.0,
        allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);

    final r = drive(p, tile, through, 120, steerPx: -200); // drag LEFT to merge in
    expect(r.committed, isTrue,
        reason: 'drag-left should spline-steer onto the surviving lane');
    expect(r.maxJump, lessThan(10), reason: 'position-continuous switch');
    expect(r.maxYawStep, lessThan(0.1), reason: 'no per-frame nose reset');
    expect(r.yawFlips, lessThanOrEqualTo(1), reason: 'no nose oscillation');
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
