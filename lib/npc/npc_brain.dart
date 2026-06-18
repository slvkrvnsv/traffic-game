import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/utils.dart';
import '../cars/npc_car.dart';
import 'npc_states/npc_state_base.dart';
import 'npc_states/state_cruising.dart';
import 'npc_states/state_following.dart';
import 'npc_states/state_yielding.dart';
import 'npc_states/state_waiting_light.dart';
import 'npc_states/state_signaling.dart';
import 'npc_states/state_pedestrian_yield.dart';

/// Simple state-machine AI for NPC cars.
///
/// Transitions are driven by sensor polling each frame.
/// Each state rpeturns a [desiredSpeed]; the car applies its own inertia.
class NpcBrain {
  // Initialized eagerly so stateName is safe before onMount fires.
  NpcState _state = StateCruising();
  double desiredSpeed = 0.0;

  // External sensor inputs — set by NpcSpawner / TileBase each frame.
  double? leadCarDistance;
  bool pedestrianInPath = false;
  bool intersectionRuleActive = false;
  bool hasRightOfWay = true;
  bool isRedLight = false;
  double distanceToTurnSignal = double.infinity;
  bool isTurning = false;

  /// Set by the merge tile while this NPC is on the ending lane and still
  /// moving over: forces the left indicator on (the curvature-based indicator
  /// logic doesn't fire while the car waits *before* the taper, with no bend
  /// yet in range). Cleared once merged.
  bool signalLeftForMerge = false;

  /// Distance to a mandatory stop point (e.g. a stop line) the NPC must halt
  /// at. Set by the tile each frame; null when there is nothing to stop for.
  double? stopTargetDistance;

  /// Tile-imposed maximum speed (e.g. a calm speed while crossing an
  /// intersection box, so a car eases out of a stop instead of flooring it).
  /// Null = no cap. Cleared by the tile when it no longer applies.
  double? speedCap;

  /// Human-readable state name for debug display.
  String get stateName => _state.runtimeType.toString().replaceFirst('State', '');

  void init(NpcCar car) {
    _state.enter(); // _state already set; just trigger the enter callback
  }

  void update(double dt, NpcCar car) {
    final sensors = NpcSensors(
      profileSpeed: car.profileSpeed,
      currentSpeed: car.speed,
      currentT: car.currentT,
      leadCarDistance: leadCarDistance,
      pedestrianInPath: pedestrianInPath,
      intersectionRuleActive: intersectionRuleActive,
      hasRightOfWay: hasRightOfWay,
      isRedLight: isRedLight,
      distanceToTurnSignal: distanceToTurnSignal,
      isTurning: isTurning,
    );

    double raw = _state.update(dt, sensors);
    // Collision avoidance overrides whatever the state requested.
    desiredSpeed = _collisionAvoidance(raw, sensors);
    // Slow down realistically into and through curves.
    desiredSpeed = _applyCurveSpeed(desiredSpeed, car);
    // Then bring us to a precise halt at any mandatory stop line.
    desiredSpeed = _applyStopTarget(desiredSpeed);
    // A tile-imposed cap (calm intersection crossing) limits the top speed but
    // never raises it — a gentle pull-out, not a launch.
    if (speedCap != null && desiredSpeed > speedCap!) desiredSpeed = speedCap!;
    _transition(car, sensors);
    _updateIndicators(car);
  }

  /// How far ahead the brain looks for an upcoming curve.
  static const double _curveScanDistance = 360.0;
  static const double _curveScanStep = 20.0;
  static const double _curveAngleThreshold = 0.25; // rad — counts as a bend

  /// Caps speed so the car brakes onto [kNpcTurnSpeed] before a curve and
  /// holds it while the path is still bending — no more taking 90° corners
  /// at full cruise speed.
  double _applyCurveSpeed(double speed, NpcCar car) {
    final s = car.spline;
    if (s == null) return speed;

    final total = s.totalLength;
    final travelled = car.distanceTravelled;
    final angleNow = s.angleAt(car.currentT);

    double? distToCurve;
    for (double d = _curveScanStep; d <= _curveScanDistance; d += _curveScanStep) {
      final t = ((travelled + d) / total).clamp(0.0, 1.0);
      final deviation = normaliseAngle(s.angleAt(t) - angleNow).abs();
      if (deviation > _curveAngleThreshold) {
        distToCurve = d - _curveScanStep; // 0 when already bending
        break;
      }
      if (t >= 1.0) break;
    }
    if (distToCurve == null) return speed; // straight ahead

    // Braking curve onto the turn speed: v = sqrt(vTurn² + 2·a·d).
    final cap = math.sqrt(
        kNpcTurnSpeed * kNpcTurnSpeed + 2 * kNpcBrakeDecel * distToCurve);
    return speed.clamp(0.0, cap);
  }

  /// Caps speed so the NPC's nose comes to rest at [stopTargetDistance] (a stop
  /// line), following the kinematic stopping curve `v = sqrt(2·a·d)`.
  double _applyStopTarget(double speed) {
    final d = stopTargetDistance;
    if (d == null) return speed;
    // Halt with the nose a little behind the line, not on it.
    final brakeDist = d - kCarLength * 0.5 - kStopLineSetback;
    if (brakeDist <= 1.0) return 0.0;
    final cap = math.sqrt(2 * kNpcBrakeDecel * brakeDist);
    return speed.clamp(0.0, cap);
  }

  /// Hard safety layer: regardless of state, cap speed on the realistic
  /// stopping curve so the NPC always halts behind the car ahead with a
  /// standing buffer — no piling up or overlapping when a queue stops. The
  /// reserved braking distance is reduced by [kNpcFollowReactionScale] so the
  /// NPC stays at speed a bit longer before it has to brake for a cut-in.
  double _collisionAvoidance(double stateSpeed, NpcSensors s) {
    final gap = s.leadCarDistance; // bumper-to-bumper, null if nothing ahead
    if (gap == null) return stateSpeed;

    final brakeDist = gap - kNpcStandingGap;
    if (brakeDist <= 0) return 0.0; // at the buffer → stop
    // v_max = sqrt(2 · a · d). Treating `a` as kNpcFollowReactionScale× the
    // reliable decel means the car reserves that much less stopping distance —
    // less twitchy when someone appears ahead, still bounded so it can stop.
    final cap =
        math.sqrt(2 * kNpcBrakeDecel * kNpcFollowReactionScale * brakeDist);
    return stateSpeed.clamp(0.0, cap);
  }

  void _transition(NpcCar car, NpcSensors s) {
    final type = _state.runtimeType;

    // ---- From Cruising ----
    if (type == StateCruising) {
      if (s.pedestrianInPath) return _go(StatePedestrianYield(), car);
      if (s.isRedLight) return _go(StateWaitingLight(), car);
      if (s.intersectionRuleActive && !s.hasRightOfWay) return _go(StateYielding(), car);
      if (s.isTurning && s.distanceToTurnSignal <= kIndicatorSignalDistance) return _go(StateSignaling(), car);
      if (s.leadCarDistance != null && s.leadCarDistance! < kNpcSafeGapDistance * 3.0) return _go(StateFollowing(), car);
    }

    // ---- From Following ----
    else if (type == StateFollowing) {
      if (s.pedestrianInPath) return _go(StatePedestrianYield(), car);
      if (s.isRedLight) return _go(StateWaitingLight(), car);
      if (s.intersectionRuleActive && !s.hasRightOfWay) return _go(StateYielding(), car);
      if (s.leadCarDistance == null || s.leadCarDistance! >= kNpcSafeGapDistance * 4.0) return _go(StateCruising(), car);
    }

    // ---- From Yielding ----
    else if (type == StateYielding) {
      if (s.pedestrianInPath) return _go(StatePedestrianYield(), car);
      if (s.hasRightOfWay) return _go(StateCruising(), car);
    }

    // ---- From WaitingLight ----
    else if (type == StateWaitingLight) {
      if (!s.isRedLight) return _go(StateCruising(), car);
    }

    // ---- From Signaling ----
    else if (type == StateSignaling) {
      if (s.pedestrianInPath) return _go(StatePedestrianYield(), car);
      if (s.isRedLight) return _go(StateWaitingLight(), car);
      if (s.intersectionRuleActive && !s.hasRightOfWay) return _go(StateYielding(), car);
      if (s.distanceToTurnSignal > kIndicatorSignalDistance) return _go(StateCruising(), car);
    }

    // ---- From PedestrianYield ----
    else if (type == StatePedestrianYield) {
      if (!s.pedestrianInPath) return _go(StateCruising(), car);
    }
  }

  void _go(NpcState next, NpcCar car) {
    debugPrint('[NPC] L${car.laneIndex} ${_state.runtimeType} → ${next.runtimeType}');
    _state.exit();
    _state = next;
    _state.enter();
  }

  /// Curvature-driven, state-independent: signals whenever the path bends
  /// within [kIndicatorSignalDistance] ahead — including while stopped at a
  /// line waiting to turn (the realistic behaviour), and switches off once
  /// the path straightens. Same logic as the player's auto-indicators.
  void _updateIndicators(NpcCar car) {
    final s = car.spline;
    if (s == null || car.hasReachedEnd) {
      car.setLeftIndicator(false);
      car.setRightIndicator(false);
      return;
    }
    // A merge in progress signals left the whole way over, even while waiting
    // for a gap before the lane actually bends.
    if (signalLeftForMerge) {
      car.setLeftIndicator(true);
      car.setRightIndicator(false);
      return;
    }
    final tAhead =
        ((car.distanceTravelled + kIndicatorSignalDistance) / s.totalLength)
            .clamp(0.0, 1.0);
    final delta = normaliseAngle(s.angleAt(tAhead) - s.angleAt(car.currentT));
    car.setLeftIndicator(delta < -0.3);
    car.setRightIndicator(delta > 0.3);
  }
}
