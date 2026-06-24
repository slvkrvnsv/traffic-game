import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';

/// REGRESSION GUARD for the edge-lean SETTLE.
///
/// Dragging toward a side with NO lane to merge into leans the car to the slight
/// [kIntentionLean] cap. Two bugs lived at that cap:
///   1. the nose SNAPPED to straight in one frame the instant the cap was reached
///      (the clamp did `_heading = 0`), instead of rolling in;
///   2. with the finger still held, the steering wheel sat CRANKED while the body
///      was straight and the car tracked straight (a phantom yaw-rate from the
///      target-up / clamp-zero oscillation) — "wheels turned, car goes straight".
/// Both are gone now: the nose eases to straight (settle), so the wheel follows it
/// to centre and the held lean is a parallel, nose-straight, wheel-straight hold.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(InputState.instance.reset);

  test('leaning into a no-lane edge rolls in and settles (no nose snap, wheel centres)',
      () {
    // A lone straight spline heading north, no neighbours → a drag leans to the cap.
    final lane = Spline([Vector2(0, 1000), Vector2(0, 500), Vector2(0, 0)]);
    final p = PlayerCar();
    p.assignSpline(lane, worldOffset: Vector2.zero());
    p.setLaneOptions([lane], Vector2.zero(), 0.0, allowLaneChange: true);
    p.position = p.splinePosition;

    var prevNose = p.extraYaw;
    var prev = p.position.clone();
    var maxNoseStep = 0.0;
    for (int i = 0; i < 60; i++) {
      p.speed = kmhToUnits(40);
      InputState.instance.setLaneSteer(200); // hold right into the no-lane edge
      p.setLaneChangeAllowed(true);
      p.update(1 / 60);
      final noseStep = (p.extraYaw - prevNose).abs();
      if (i > 0) maxNoseStep = noseStep > maxNoseStep ? noseStep : maxNoseStep;
      prevNose = p.extraYaw;
      // Steady-state checks, once it has had time to reach the cap and settle.
      if (i >= 45) {
        final latMove = (p.position - prev).x.abs();
        expect(p.lateralOffset, closeTo(kIntentionLean, 0.6),
            reason: 'holds at the slight lean cap');
        expect(p.extraYaw.abs(), lessThan(0.02),
            reason: 'body settles STRAIGHT (parallel to the lane), no held lean angle');
        expect((p.steerOverride ?? 0).abs(), lessThan(0.05),
            reason: 'wheel CENTRES once settled — not cranked while the car is straight');
        expect(latMove, lessThan(0.05), reason: 'car tracks straight at the held offset');
      }
      prev = p.position.clone();
    }

    // The nose must EASE to straight, never snap — the old clamp dropped it ~0.42rad
    // (full lean → 0) in a single frame.
    expect(maxNoseStep, lessThan(0.15),
        reason: 'the nose rolls in at the slew rate; it must not snap straight at the cap');
  });
}
