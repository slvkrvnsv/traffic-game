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

  /// Mirror of [forceLeftIndicator] for a forced RIGHT indicator — set by a
  /// multi-lane intersection while the player must move to (or hold) the right
  /// lane for the commanded maneuver, before the lane visibly bends. Cleared by
  /// the tile once the lane change is no longer the active task.
  bool forceRightIndicator = false;

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

  /// Per-frame update of whether steering is allowed at the player's current
  /// position — TileManager feeds this from the active tile's positional rule
  /// ([TileBase.allowsLaneChangeAt]), so a merge/widen lane can turn steering
  /// on/off mid-tile rather than only per-tile.
  void setLaneChangeAllowed(bool allowed) => _laneChangeAllowed = allowed;

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

  /// True once the current finger-drag has committed a lane change. While set,
  /// steering input is ignored and the car settles onto the chosen lane — so a
  /// single drag is ONE decisive lane change, not a continuous shove that keeps
  /// dragging / re-committing. Reset when the finger lifts; to change again the
  /// player drags afresh.
  bool _steerConsumed = false;

  /// Fork spline-steer targets for the current position (set per-frame by
  /// TileManager from [TileBase.splineSteerTargetAt]): the spline a left/right
  /// drag switches onto where two lanes are still near-coincident but splitting
  /// (a widen fork). Non-null ⇒ the car is in a fork and uses spline-steering.
  Spline? _forkLeft;
  Spline? _forkRight;

  /// Per-frame fork targets from the active tile (see [_forkLeft]/[_forkRight]).
  void setForkTargets(Spline? left, Spline? right) {
    _forkLeft = left;
    _forkRight = right;
  }

  void _updateLaneChange(double dt) {
    final input = InputState.instance;

    // A drag is one decisive lane change: once it commits, [_steerConsumed]
    // drops the finger's influence so the car settles onto the chosen lane
    // instead of being shoved further. Lifting the finger re-arms it.
    if (!input.laneSteerActive) _steerConsumed = false;

    // Fork (a widen lane just splitting off — TileManager set the targets):
    // spline-steer. A drag switches WHICH spline we follow (seamless — the lanes
    // are near-coincident) and the offset then self-centres onto it. The
    // offset-based lean is skipped here entirely: it jumps as the edge-pull cap
    // collapses to the opening lane's separation, and wobbles because each
    // cap-clamp resets the nose. The spline's own geometry carries the car over.
    final inFork = _forkLeft != null || _forkRight != null;
    if (inFork && _laneChangeAllowed && !_steerConsumed && input.laneSteerActive) {
      final px = input.laneSteerPx;
      final target = px > kLaneSteerDeadzone
          ? _forkRight
          : (px < -kLaneSteerDeadzone ? _forkLeft : null);
      if (target != null && spline != null && !identical(spline, target)) {
        _switchSplineSeamless(target);
        _steerConsumed = true;
      }
    }

    // [_laneChangeAllowed] is set per-frame by TileManager from the tile's
    // positional rule (TileBase.allowsLaneChangeAt). When steering is off
    // (released, consumed, tile-disabled, or in a fork) the car runs the
    // slew-limited self-centre onto its current lane.
    final steerActive = input.laneSteerActive &&
        _laneChangeAllowed &&
        !_steerConsumed &&
        !inFork;

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
    //    The cap is the *actual* separation to the adjacent lane, not a fixed
    //    lane width — so a lane that diverges in (merge) or out (widen) is
    //    reachable as soon as it has opened even slightly, instead of being
    //    unreachable until it happens to be a full lane away. For ordinary
    //    parallel lanes the separation is exactly kLaneWidth, so this is
    //    identical to the old behaviour there.
    // Skipped in a fork: there the spline-switch is the lane change, and a cap
    // clamp here would reset the nose every frame as the lane's separation
    // drifts — that per-frame reset is exactly the fork wobble.
    final sepRight = _adjacentSeparation(1);
    final sepLeft = _adjacentSeparation(-1);
    final maxRight = sepRight ?? kLaneWidth * kLaneEdgePullFraction;
    final maxLeft = sepLeft ?? kLaneWidth * kLaneEdgePullFraction;
    final capped = lateralOffset.clamp(-maxLeft, maxRight);
    if (!inFork && capped != lateralOffset) {
      lateralOffset = capped;
      _heading = 0.0;
    }

    // 5. Commit once the car has arced past [kLaneCommitFraction] of the way to
    //    the adjacent lane, rebasing by that lane's ACTUAL separation so the
    //    move is position-continuous even when the lanes aren't a full width
    //    apart. (Recompute the separation each step — it changes after a
    //    commit.) For parallel lanes the separation is kLaneWidth, matching the
    //    old fixed rebase exactly.
    // Commits are suppressed until the adjacent lane is genuinely separated —
    // see [kMinLaneCommitSeparation]. Near-coincident lanes (an opening/closing
    // taper lane) would otherwise click and ping-pong on a hair of offset.
    while (true) {
      final sep = _adjacentSeparation(1);
      if (sep == null ||
          sep < kMinLaneCommitSeparation ||
          lateralOffset < sep * kLaneCommitFraction) {
        break;
      }
      if (!_commitToAdjacent(1)) break;
      lateralOffset -= sep; // rebase onto new lane; heading continuous
      _steerConsumed = true; // one drag = one lane; finger dropped until release
      HapticFeedback.selectionClick();
    }
    while (true) {
      final sep = _adjacentSeparation(-1);
      if (sep == null ||
          sep < kMinLaneCommitSeparation ||
          lateralOffset > -sep * kLaneCommitFraction) {
        break;
      }
      if (!_commitToAdjacent(-1)) break;
      lateralOffset += sep;
      _steerConsumed = true; // one drag = one lane; finger dropped until release
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

  /// Separation (world units) to the nearest lane on [direction] (+1 right / -1
  /// left) of the current lane, or null if there is none. The lane-change cap
  /// and commit use this so a merging/diverging lane (variable spacing) is
  /// handled the same as parallel lanes — where it simply equals [kLaneWidth].
  double? _adjacentSeparation(int direction) {
    final current = spline;
    if (current == null || _laneOptions.length < 2) return null;
    final centre = _laneWorldPoint(current);
    final a = splineAngle;
    final perp = Vector2(-math.sin(a), math.cos(a));
    double? best;
    for (final lane in _laneOptions) {
      if (identical(lane, current)) continue;
      final proj = (_laneWorldPoint(lane) - centre).dot(perp);
      if (proj * direction <= 1.0) continue; // not on this side (or too close)
      final sep = proj.abs();
      if (best == null || sep < best) best = sep;
    }
    return best;
  }

  /// Spline-steer onto [target]: switch the followed spline while keeping the
  /// car's world position continuous (rebase [lateralOffset] by the lanes'
  /// current perpendicular separation). At a fork the lanes are near-coincident
  /// so the rebase is tiny; the self-centre then slides the car onto [target].
  void _switchSplineSeamless(Spline target) {
    final current = spline;
    if (current == null) return;
    final a = splineAngle;
    final perp = Vector2(-math.sin(a), math.cos(a));
    final sep = (_laneWorldPoint(target) - _laneWorldPoint(current)).dot(perp);
    assignSpline(
      target,
      startDistance: currentT * target.totalLength,
      worldOffset: _laneTileOffset,
      worldAngle: _laneTileAngle,
    );
    lateralOffset -= sep; // keep the world position continuous across the switch
    HapticFeedback.selectionClick();
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
    // the ending lane), before the lane has visibly bent. A multi-lane
    // intersection forces the indicator toward the lane the player must take.
    if (forceLeftIndicator) {
      setLeftIndicator(true);
      setRightIndicator(false);
      return;
    }
    if (forceRightIndicator) {
      setLeftIndicator(false);
      setRightIndicator(true);
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
