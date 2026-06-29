import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_config.dart';

/// REGRESSION GUARD for the seam dead-band merge jump.
///
/// The light intersection's lanes used to be chopped into approach/mid/through stubs
/// (so each chop could be a fork node). The parallel-lane merge searches the neighbour
/// for its nearest point and reports "no lane here" at a stub ENDPOINT — so at every
/// seam between two of the neighbour's stubs there was a ~12–16px band where the merge
/// found no adjacent lane, the cap collapsed from the real 80u separation to the 12u
/// intention-lean, and the clamp SLAMMED the car sideways (~30px in one frame) and
/// killed the merge mid-flight. It hit "here and there" because there were four seams.
///
/// The fix: each lane is ONE continuous spline (turns TAP on, they don't chop it), so
/// the merge always sees a continuous neighbour. These tests drive a real mid-lean
/// merge straight through the old dead-band depths and assert there is NO single-frame
/// lateral snap and the merge actually COMPLETES — pure PlayerCar + the real splines,
/// the path that would have caught the bug.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(InputState.instance.reset);

  IntersectionLightTile place() => IntersectionLightTile(config: LaneConfig.l1)
    ..place(worldPosition: Vector2.zero(), orientation: 0.0);

  /// Place the player mid-corridor on [fromInner]'s spine at local [startY], lane
  /// options = the whole corridor, and hold the steer [steer]. Drive until it lands on
  /// the other spine. Returns (merged, maxFrameJump): did it reach the other spine, and
  /// the largest single-frame lateral (x) move seen (a clamp snap shows up here).
  ({bool merged, double maxJump}) driveMerge(
      IntersectionLightTile tile, bool fromInner, double startY, double steer) {
    final p = PlayerCar();
    p.assignSpline(tile.approach(inner: fromInner),
        startDistance: 1640 - startY, worldOffset: Vector2.zero());
    p.setLaneOptions(tile.playerLaneMates(tile.approach(inner: fromInner)),
        Vector2.zero(), 0.0, allowLaneChange: true);
    p.position = p.splinePosition;
    p.speed = kmhToUnits(40);
    InputState.instance.setGasLevel(1.0);
    InputState.instance.setLaneSteer(steer);

    final target = tile.approach(inner: !fromInner);
    var prev = p.position.clone();
    double maxJump = 0;
    var merged = false;
    for (int i = 0; i < 600 && !p.hasReachedEnd; i++) {
      p.setLaneChangeAllowed(tile.allowsLaneChangeAt(tile.worldToLocal(p.position)));
      p.update(1 / 60);
      final dx = (p.position.x - prev.x).abs(); // travel is ~north, so lateral = x
      if (dx > maxJump) maxJump = dx;
      prev = p.position.clone();
      if (identical(p.spline, target)) {
        merged = true;
        break;
      }
    }
    return (merged: merged, maxJump: maxJump);
  }

  test('rightward merge through the box (old outer seams 980/900) — no snap, completes',
      () {
    // Start mid-lean at y≈1010 so the lean is still building as it crosses the old
    // dead-bands; the pre-fix bug slammed ~30u at y≈900 and stranded the car.
    final r = driveMerge(place(), true, 1010, 200);
    expect(r.merged, isTrue,
        reason: 'the rightward corridor merge must COMPLETE onto the outer spine');
    expect(r.maxJump, lessThan(4),
        reason: 'no seam dead-band snap (the old chopped lanes jumped ~30u here)');
  });

  test('leftward merge through the box (old inner seams 860/780) — no snap, completes',
      () {
    final r = driveMerge(place(), false, 940, -200);
    expect(r.merged, isTrue,
        reason: 'the leftward corridor merge must COMPLETE onto the inner spine');
    expect(r.maxJump, lessThan(4), reason: 'no seam dead-band snap on the inner seams');
  });

  test('a long-runway merge is also smooth (sanity: the happy path never snapped)', () {
    final r = driveMerge(place(), true, 1400, 200);
    expect(r.merged, isTrue);
    expect(r.maxJump, lessThan(4));
  });
}
