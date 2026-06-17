import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/spline.dart';
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

  /// Speed-dependent acceleration: full launch punch from a standstill, fading
  /// linearly toward [kPlayerAccelFloor] of it at top speed. So pulling away is
  /// brisk, but each extra km/h gets harder to gain — like a real car running
  /// out of breath in the upper range.
  @override
  double accelerationAt(double currentSpeed) {
    final t = (currentSpeed / kPlayerMaxSpeed).clamp(0.0, 1.0);
    final factor = 1.0 - (1.0 - kPlayerAccelFloor) * t;
    return kPlayerLaunchAccel * factor;
  }

  // ---------------------------------------------------------------------------
  // Lane options for the current tile (set by TileManager on each assignment).
  // ---------------------------------------------------------------------------
  List<Spline> _laneOptions = const [];
  Vector2 _laneTileOffset = Vector2.zero();
  double _laneTileAngle = 0.0;
  bool _laneChangeAllowed = true;

  /// Set by the merge tile while the player is in the ending lane with the
  /// "Merge left" task active: forces the left indicator on (the curvature-based
  /// auto-indicator wouldn't fire until the lane visibly bends). Cleared by the
  /// tile once merged / out of the lane.
  bool forceLeftIndicator = false;

  /// Record the parallel travel lanes available on the player's current tile,
  /// plus that tile's world placement, so a swipe can switch between them.
  /// [allowLaneChange] is the tile's own verdict (single-lane maneuver tiles
  /// say no): when false the steering input is ignored entirely, so the player
  /// can't manoeuvre on top of a commanded turn — it's lane changing, not
  /// driving the turn.
  void setLaneOptions(
    List<Spline> lanes,
    Vector2 tileOffset,
    double tileAngle, {
    bool allowLaneChange = true,
  }) {
    _laneOptions = lanes;
    _laneTileOffset = tileOffset.clone();
    _laneTileAngle = tileAngle;
    _laneChangeAllowed = allowLaneChange;
  }

  @override
  void update(double dt) {
    _readInput();
    _updateLaneChange(dt);
    super.update(dt); // updates speed via CarBase._updateMotion
    _updateAutoIndicators();
    SpeedState.instance.updateFromUnits(speed);
  }

  // ---------------------------------------------------------------------------
  // Lane change — speed-driven steering
  //
  // The finger sets a steering intent (-1 left .. +1 right). The car's lateral
  // movement is produced by its own motion: lateral speed = steer × forward
  // speed × ratio. So lane changes are quick at speed, slow at low speed, and
  // impossible when stopped — the control is tied to the car, not the finger.
  // Once the car has actually travelled past the commit point the lane sticks
  // (spline switches, offset rebases, selection-click haptic).
  // ---------------------------------------------------------------------------

  /// World point of [lane] (centreline, no offset) at the player's progress.
  Vector2 _laneWorldPoint(Spline lane) {
    final local = lane.evaluate(currentT);
    final cosA = math.cos(_laneTileAngle);
    final sinA = math.sin(_laneTileAngle);
    return Vector2(
      _laneTileOffset.x + local.x * cosA - local.y * sinA,
      _laneTileOffset.y + local.x * sinA + local.y * cosA,
    );
  }

  /// Body yaw relative to the lane heading (radians, + = nose toward the right).
  double _heading = 0.0;

  void _updateLaneChange(double dt) {
    final input = InputState.instance;

    // Single-lane tiles (intersection maneuvers, start) disallow lane changes:
    // the road is performing a commanded turn and the player shouldn't be
    // manoeuvring on top of it. Treat steering as released so the car simply
    // holds (and gently re-centres on) its lane. The release path is
    // slew-rate-limited, so it eases in/out without a snap.
    final steerActive = input.laneSteerActive && _laneChangeAllowed;

    // 1. Target nose angle + how fast the nose may turn toward it. Turn-in is
    //    crisp; the self-centring return is deliberately lazier (safe abort).
    final double target;
    final double slewRate;
    if (steerActive) {
      final steer = (input.laneSteerPx / kSteerInputRange).clamp(-1.0, 1.0);
      target = steer * kMaxBodyYaw;
      slewRate = kHeadingSlewRate;
    } else {
      // Self-centre: nose points back in proportion to how far off-lane. As the
      // offset shrinks the nose straightens, so the return decays monotonically
      // — no overshoot, no bounce, at any speed. Non-saturating by design.
      target = (-kReturnGain * lateralOffset).clamp(-kMaxBodyYaw, kMaxBodyYaw);
      slewRate = kReturnSlewRate;
    }

    // 2. Slew the nose toward the target at the capped rate (steering-wheel
    //    speed), scaled by car speed so low-speed changes are sluggish and a
    //    stopped car cannot turn. A rate limit — not easing — keeps the slew
    //    independent of the return gain, so it can't reintroduce a bounce.
    final sf = (speed / kHeadingFullSpeed).clamp(0.0, 1.0);
    final maxStep = slewRate * sf * dt;
    final headingBefore = _heading;
    _heading += (target - _heading).clamp(-maxStep, maxStep);
    final yawRate = dt > 0 ? (_heading - headingBefore) / dt : 0.0;

    // 3. Lateral movement is purely a consequence of pointing off-axis. While
    //    self-centring (finger released, or any no-steer tile) the nose can lag
    //    on the old steer side for a moment; clamp the step so it may only ever
    //    move TOWARD the lane, never away. That makes the return strictly
    //    monotonic, so the car glues onto its spline the instant steering goes
    //    away — e.g. handing off from the merge tile to the straight road — with
    //    no drift-out-then-correct wobble.
    final lateralStep = speed * math.sin(_heading) * dt;
    if (steerActive) {
      lateralOffset += lateralStep;
    } else {
      final next = lateralOffset + lateralStep;
      if (next.abs() <= lateralOffset.abs()) {
        lateralOffset = next; // converging toward the lane — apply
      } else if (next.sign != lateralOffset.sign) {
        lateralOffset = 0.0; // overshot the centreline — settle on it
      }
      // else: same side and growing (a stale nose angle) — hold this frame and
      // let the nose straighten first, rather than drifting off-lane.
    }

    // Settle exactly once centred and straight (released only).
    if (!steerActive &&
        lateralOffset.abs() < 0.5 &&
        _heading.abs() < 0.005) {
      lateralOffset = 0.0;
      _heading = 0.0;
    }

    // 4. Cap the lean at the available lanes; straighten the nose at the edge.
    final maxRight =
        _hasAdjacent(1) ? kLaneWidth : kLaneWidth * kLaneEdgePullFraction;
    final maxLeft =
        _hasAdjacent(-1) ? kLaneWidth : kLaneWidth * kLaneEdgePullFraction;
    final capped = lateralOffset.clamp(-maxLeft, maxRight);
    if (capped != lateralOffset) {
      lateralOffset = capped;
      _heading = 0.0;
    }

    // 5. Commit once the car has actually arced past the commit point.
    final commitDist = kLaneWidth * kLaneCommitFraction;
    while (lateralOffset >= commitDist && _commitToAdjacent(1)) {
      lateralOffset -= kLaneWidth; // rebase onto new lane; heading continuous
      HapticFeedback.selectionClick();
    }
    while (lateralOffset <= -commitDist && _commitToAdjacent(-1)) {
      lateralOffset += kLaneWidth;
      HapticFeedback.selectionClick();
    }

    // 6. Body points along its true heading. The front wheels follow the YAW
    //    RATE, not the yaw angle — a steering angle changes the heading, it
    //    doesn't hold it. So the wheels crank while the nose is turning and sit
    //    straight while the car glides across at a steady angle (physically
    //    correct). null when settled, so spline-curvature steering drives turns.
    extraYaw = _heading;
    final manoeuvring = steerActive || _heading.abs() > 0.005;
    steerOverride = manoeuvring
        ? math.atan(kSteerWheelBase * yawRate / math.max(speed, kWheelSpeedFloor))
            .clamp(-0.6, 0.6)
        : null;
  }

  /// Whether a lane exists on [direction] (+1 right / -1 left) of the current
  /// lane, without switching to it.
  bool _hasAdjacent(int direction) {
    final current = spline;
    if (current == null || _laneOptions.length < 2) return false;
    final centre = _laneWorldPoint(current);
    final a = splineAngle;
    final perp = Vector2(-math.sin(a), math.cos(a));
    for (final lane in _laneOptions) {
      if (identical(lane, current)) continue;
      final proj = (_laneWorldPoint(lane) - centre).dot(perp);
      if (proj * direction > 1.0) return true;
    }
    return false;
  }

  /// Switch the spline to the adjacent lane on [direction] (+1 right / -1 left)
  /// if one exists, preserving forward progress. Returns true on success.
  /// The caller rebases [lateralOffset] so the move is visually seamless.
  bool _commitToAdjacent(int direction) {
    final current = spline;
    if (current == null || _laneOptions.length < 2) return false;

    final centre = _laneWorldPoint(current); // current lane centreline
    final a = splineAngle;
    final perp = Vector2(-math.sin(a), math.cos(a));

    Spline? best;
    double bestProj = double.infinity;
    for (final lane in _laneOptions) {
      if (identical(lane, current)) continue;
      final proj = (_laneWorldPoint(lane) - centre).dot(perp);
      if (proj * direction <= 1.0) continue; // wrong side
      if (proj.abs() < bestProj) {
        bestProj = proj.abs();
        best = lane;
      }
    }
    if (best == null) return false;

    assignSpline(
      best,
      startDistance: currentT * best.totalLength,
      worldOffset: _laneTileOffset,
      worldAngle: _laneTileAngle,
    );
    return true;
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
    // A commanded merge signals left from the moment the task appears (while in
    // the ending lane), before the lane has visibly bent.
    if (forceLeftIndicator) {
      setLeftIndicator(true);
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
