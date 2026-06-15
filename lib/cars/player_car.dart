import '../core/constants.dart';
import '../core/utils.dart';
import '../input/input_state.dart';
import '../input/speed_state.dart';
import 'car_base.dart';
import 'car_variants.dart';

/// The player-controlled car.
///
/// The trajectory is determined by the active spline (assigned by TileManager).
/// The player only controls speed via Gas (accelerate) and Brake (decelerate).
/// Indicators are automatic: the route is commanded by the game (exam-style),
/// so the car signals like a well-behaved examinee whenever a turn is near.
class PlayerCar extends CarBase {
  PlayerCar()
      : super(
          definition: CarVariants.player,
          priority: 10,
        );

  @override
  double get rollingDrag => kPlayerRollingDrag;

  @override
  void update(double dt) {
    _readInput();
    super.update(dt); // updates speed via CarBase._updateMotion
    _updateAutoIndicators();
    SpeedState.instance.updateFromUnits(speed);
  }

  /// Signal when the path bends within [kIndicatorSignalDistance] ahead;
  /// stays on through the curve and switches off once the path straightens.
  void _updateAutoIndicators() {
    final s = spline;
    if (s == null || hasReachedEnd) {
      setLeftIndicator(false);
      setRightIndicator(false);
      return;
    }
    final tAhead =
        ((distanceTravelled + kIndicatorSignalDistance) / s.totalLength)
            .clamp(0.0, 1.0);
    final delta = normaliseAngle(s.angleAt(tAhead) - s.angleAt(currentT));
    setLeftIndicator(delta < -0.3);
    setRightIndicator(delta > 0.3);
  }

  void _readInput() {
    final input = InputState.instance;

    if (input.brakeLevel > 0) {
      targetSpeed = 0.0;
      isBraking = true;
      brakeFraction = input.brakeLevel;
    } else if (input.gasLevel > 0) {
      targetSpeed = input.gasLevel * kPlayerMaxSpeed;
      isBraking = false;
      brakeFraction = 1.0;
    } else {
      targetSpeed = 0.0;
      isBraking = false;
      brakeFraction = 1.0;
    }
  }

  @override
  void onSplineEnd(double overflow) {
    // TileManager hands the player to the next tile's spline at t=1.0 — no-op.
  }
}
