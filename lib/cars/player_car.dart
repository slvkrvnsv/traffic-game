import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/game_bus.dart';
import '../core/spline.dart';
import '../core/utils.dart';
import '../input/input_state.dart';
import '../input/speed_state.dart';
import 'car_base.dart';
import 'car_variants.dart';

/// The player-controlled car.
///
/// The trajectory is determined by the active spline (assigned by TileManager).
/// The player controls speed via Gas (accelerate) and Brake (decelerate), and
/// arms the turn signal manually via the HUD blinker buttons. The route is
/// commanded by the game (exam-style), but indicating the commanded turn is on
/// the player — only the self-cancel (clearing the blinker once the turn has
/// been driven through) is automatic, like a real car's stalk.
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
    _updateSignalAutoCancel(); // may clear the blinker as a turn completes
    _readManualSignals();
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
  Vector2 _laneWorldPoint(Spline lane) => _laneWorldPointAtT(lane, currentT);

  /// World point of [lane] (centreline, no offset) at an explicit progress [t].
  Vector2 _laneWorldPointAtT(Spline lane, double t) {
    final local = lane.evaluate(t);
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

  void _updateLaneChange(double dt) {
    final input = InputState.instance;

    // A drag is one decisive lane change: once it commits, [_steerConsumed]
    // drops the finger's influence so the car settles onto the chosen lane
    // instead of being shoved further. Lifting the finger re-arms it.
    if (!input.laneSteerActive) _steerConsumed = false;

    // The offset lean/merge runs on EVERY tile — the universal SLIDE primitive: a
    // drag toward a parallel lane merges (equal-width road lanes, an intersection's
    // two through lanes, AND the lane-transition connector's tapering merge/widen
    // lane all run this same offset-cap-commit code, sharing [_nearestLateral] so a
    // staggered/converging lane is handled exactly like parallel ones); a drag with
    // no lane that way leans ≤[kIntentionLean] to show intention (the side the next
    // fork node will pick). A merge commit sets [_steerConsumed] so one drag = one
    // decisive lane change (the car then settles on the new lane, not edge-pulling
    // past it). Holding the finger THROUGH a merge stops showing a visible lean — but
    // a junction fork still picks correctly: [leanSign] falls back to the live drag
    // direction when the offset has settled, so "keep dragging right after I merged →
    // I go right" holds at the node.
    final steerActive = input.laneSteerActive &&
        _laneChangeAllowed &&
        !_steerConsumed;

    // The lean cap = the ACTUAL separation to the adjacent lane (so a diverging /
    // widening lane is reachable the moment it opens), or — with NO lane that way — a
    // SLIGHT [kIntentionLean] edge-pull: the intention hint (which side the next fork
    // node will pick), universal on every tile. Computed up here (not just at the
    // clamp) so the nose can SETTLE as the lean reaches the edge — see step 1.
    final sepRight = _adjacentSeparation(1);
    final sepLeft = _adjacentSeparation(-1);
    const edgeCap = kIntentionLean;
    final maxRight = sepRight ?? edgeCap;
    final maxLeft = sepLeft ?? edgeCap;

    // 1. Target nose angle + how fast the nose may turn toward it. Turn-in is
    //    crisp; the self-centring return (and the edge settle) is deliberately lazier.
    final double target;
    final double slewRate;
    if (steerActive) {
      final steer = (input.laneSteerPx / kSteerInputRange).clamp(-1.0, 1.0);
      // Dragging INTO an edge already reached (offset at the cap on the drag side, no
      // lane to merge there) → ease the nose back to STRAIGHT to HOLD the lean. A car
      // parked at a constant offset drives PARALLEL to the lane (nose 0); if the nose
      // kept pointing out it would (a) snap straight the instant the clamp pinned the
      // offset, and (b) sit cranked — wheels turned — while the car tracks straight.
      // Rolling it down at the lazy return rate is the "rolls in and settles" feel.
      final intoRightCap = steer > 0 && lateralOffset >= maxRight - 0.5;
      final intoLeftCap = steer < 0 && lateralOffset <= -maxLeft + 0.5;
      if (intoRightCap || intoLeftCap) {
        target = 0.0;
        slewRate = kReturnSlewRate;
      } else {
        target = steer * kMaxBodyYaw;
        slewRate = kHeadingSlewRate;
      }
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
    final offsetBefore = lateralOffset; // this frame's start, before any step moves it
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

    // 4. Hold the lean at the cap (computed above). The clamp ONLY cancels OUTWARD
    //    growth past the cap this frame — it must NOT slam a LARGER carried offset
    //    (left by a just-finished merge / fork / hand-off) down in one frame; the
    //    self-centre (step 3) eases that in at the physical crab speed. That GLIDE is
    //    what stops "snaps onto the new spline too fast": a turn taken right after a
    //    merge sees its sibling exit lane start staggered ahead, the cap momentarily
    //    collapses to [kIntentionLean], and a ~30u carried offset would be yanked to
    //    12u in one frame. The nose is rolled to straight by step 1's edge-settle, so
    //    the clamp NO LONGER zeroes the heading — that instant zero was the nose-snap
    //    AND the wheels-turned-while-the-car-tracks-straight bug.
    if (lateralOffset > maxRight && lateralOffset > offsetBefore) {
      lateralOffset = math.max(maxRight, offsetBefore);
    } else if (lateralOffset < -maxLeft && lateralOffset < offsetBefore) {
      lateralOffset = math.min(-maxLeft, offsetBefore);
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
      _gradeLaneChangeCommit(1); // right blinker on → drop it; off → fault
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
      _gradeLaneChangeCommit(-1); // left blinker on → drop it; off → fault
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

  /// The nearest point on [lane] to the player right now — its progress [t] and the
  /// signed perpendicular offset — or null when the player is past [lane]'s extent
  /// (before its start or beyond its end). Public seam for the turn-commit ZONE
  /// ([TileManager.branchToCommit]): a turn is taken by projecting onto its branch,
  /// the same nearest-point logic the parallel-lane merge uses.
  ({double t, double lateral})? nearestOn(Spline lane) => _nearestLateral(lane);

  /// The point on [lane] NEAREST the player's current centre: its progress [t] and
  /// the signed lateral offset (perp·(lanePoint − me); + = right of travel). Returns
  /// null when the nearest point is an endpoint — i.e. the player is past [lane]'s
  /// extent, so it isn't laterally adjacent here (no merge target). Using the
  /// nearest point (not the same fraction) keeps a lane change position-continuous
  /// even when the lanes DON'T start at the same depth — e.g. the intersection's
  /// two through lanes after the per-lane fork, or any future staggered lanes. For
  /// ordinary equal-length parallel lanes the nearest point is at the same fraction,
  /// so this is identical to the old behaviour.
  ({double t, double lateral})? _nearestLateral(Spline lane) {
    final cur = spline;
    if (cur == null) return null;
    final me = _laneWorldPoint(cur);
    double d2at(double t) => (_laneWorldPointAtT(lane, t) - me).length2;
    // Coarse nearest sample, then refine (ternary search on the smooth distance)
    // so the switch point is the EXACT nearest — a quantised sample would land the
    // car a few px off the lane and read as a jump on an ordinary lane change.
    double bt = 0.0, bd = double.infinity;
    const n = 24;
    for (int i = 0; i <= n; i++) {
      final t = i / n;
      final d2 = d2at(t);
      if (d2 < bd) {
        bd = d2;
        bt = t;
      }
    }
    // Refine (ternary on the smooth distance) for the EXACT nearest t, THEN judge "past
    // the lane" from that — not the coarse argmin (which snaps to the t=0/1 endpoint
    // within 1/n of an end, falsely nulling the last ~4% before a tile seam → a mid-merge
    // car saw its neighbour vanish and the clamp slammed it sideways) and NOT the endpoint
    // tangents (a sharply-curved turn lane rotates 90°, so a point abreast of its straight
    // run reads as "before the north-facing start" and the right post-turn merge went
    // dead). The nearest is genuinely PAST the lane only when it pins to a boundary AND the
    // distance is still falling toward it; an interior nearest — even a hair from an end,
    // or on a 90°-turned lane — is adjacent.
    double lo = (bt - 1.0 / n).clamp(0.0, 1.0);
    double hi = (bt + 1.0 / n).clamp(0.0, 1.0);
    for (int k = 0; k < 16; k++) {
      final m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
      if (d2at(m1) < d2at(m2)) {
        hi = m2;
      } else {
        lo = m1;
      }
    }
    bt = (lo + hi) / 2;
    // "Past the lane" only when the refined (global) nearest PINS to an end AND the
    // distance is still falling toward it — judged with that end's LOCAL tangent. So a
    // 90°-turned lane (nearest interior on its straight run) stays adjacent (the right
    // post-turn merge), a car merely abreast of an end stays adjacent (the last 4% before
    // a tile seam), and only a car genuinely BEYOND an end is dropped. Endpoint tangents
    // alone failed on curves; a coarse-argmin or eps cutoff failed at the seam.
    const eps = 1e-3;
    final cosA = math.cos(_laneTileAngle), sinA = math.sin(_laneTileAngle);
    double alongAt(double t) {
      final lt = lane.tangent(t);
      final tan = Vector2(lt.x * cosA - lt.y * sinA, lt.x * sinA + lt.y * cosA);
      return (_laneWorldPointAtT(lane, t) - me).dot(tan);
    }

    if (bt >= 1.0 - eps && alongAt(1.0) < 0) return null; // pinned beyond the far end
    if (bt <= eps && alongAt(0.0) > 0) return null; // pinned before the near start
    final a = splineAngle;
    final perp = Vector2(-math.sin(a), math.cos(a));
    return (t: bt, lateral: (_laneWorldPointAtT(lane, bt) - me).dot(perp));
  }

  /// Separation (world units) to the nearest lane on [direction] (+1 right / -1
  /// left) of the current lane, or null if there is none. The lane-change cap and
  /// commit use this so a merging/diverging/staggered lane is handled the same as
  /// parallel lanes — where it simply equals [kLaneWidth].
  double? _adjacentSeparation(int direction) {
    final current = spline;
    if (current == null || _laneOptions.length < 2) return null;
    double? best;
    for (final lane in _laneOptions) {
      if (identical(lane, current)) continue;
      final n = _nearestLateral(lane);
      if (n == null) continue;
      if (n.lateral * direction <= 1.0) continue; // not on this side (or too close)
      final sep = n.lateral.abs();
      if (best == null || sep < best) best = sep;
    }
    return best;
  }

  /// The player's current lateral intention: -1 (holding left), +1 (right), 0
  /// (neutral). Used by TileManager to pick the branch at a junction fork node.
  /// Reads ONLY the live finger — NOT the residual lean — so a release just before
  /// the node goes straight immediately ("leave and you go straight, attach to the
  /// straight spline right away"). The cosmetic lean eases back lazily, so reading it
  /// would still turn for a few tenths of a second after release; the finger is the
  /// faithful signal. A held-through drag and a merge-then-hold both still pick the
  /// turn (the finger is down at the node either way).
  int get leanSign {
    final input = InputState.instance;
    if (!input.laneSteerActive) return 0;
    if (input.laneSteerPx < -kLaneSteerDeadzone) return -1;
    if (input.laneSteerPx > kLaneSteerDeadzone) return 1;
    return 0;
  }

  /// Commit a TURN onto [branch] (chosen by TileManager from the lean): switch the
  /// followed spline to [branch] at [startDistance] — the NEAREST point on it, so the
  /// turn is takeable anywhere the branch still hugs the lane (a commit ZONE, not one
  /// knife-edge point at the branch start). The car's WORLD position is kept continuous
  /// by rebasing the lean against the branch; any small leftover offset (the branch had
  /// diverged a little by the commit point) then glides out via the self-centre — so a
  /// turn taken late slides smoothly onto the branch instead of snapping. Reset the lane
  /// set to [laneOptions] (the branch's siblings) and click.
  void commitFork(
    Spline branch,
    List<Spline> laneOptions,
    Vector2 tileOffset,
    double tileAngle, {
    double startDistance = 0.0,
    bool haptic = true,
  }) {
    final worldBefore = splinePosition; // actual world point (centre + current lean)
    assignSpline(branch,
        startDistance: startDistance,
        worldOffset: tileOffset,
        worldAngle: tileAngle);
    // Rebase the lean so the world position doesn't jump across the switch; the
    // self-centre glides the (small) residual to the branch centreline.
    final a = splineAngle;
    final perp = Vector2(-math.sin(a), math.cos(a));
    lateralOffset = (worldBefore - splineCentrePosition).dot(perp);
    setLaneOptions(laneOptions, tileOffset, tileAngle, allowLaneChange: true);
    _steerConsumed = false;
    // Click only when the fork is a TURN (or a merge, handled in _commitToAdjacent):
    // sliding straight through a junction shouldn't buzz.
    if (haptic) HapticFeedback.selectionClick();
    _gradeTurnSignal(branch); // global fault if a real turn was taken unsignalled
  }

  /// Switch the spline to the adjacent lane on [direction] (+1 right / -1 left)
  /// if one exists, preserving forward progress. Returns true on success.
  /// The caller rebases [lateralOffset] so the move is visually seamless.
  bool _commitToAdjacent(int direction) {
    final current = spline;
    if (current == null || _laneOptions.length < 2) return false;

    Spline? best;
    double bestSep = double.infinity;
    double bestT = 0.0;
    for (final lane in _laneOptions) {
      if (identical(lane, current)) continue;
      final n = _nearestLateral(lane);
      if (n == null) continue;
      if (n.lateral * direction <= 1.0) continue; // wrong side
      if (n.lateral.abs() < bestSep) {
        bestSep = n.lateral.abs();
        best = lane;
        bestT = n.t; // switch at the nearest point → same world position, any geometry
      }
    }
    if (best == null) return false;

    assignSpline(
      best,
      startDistance: bestT * best.totalLength,
      worldOffset: _laneTileOffset,
      worldAngle: _laneTileAngle,
    );
    return true;
  }

  /// Mirror the player's manual blinker (the HUD's `<` / `>` buttons) onto the
  /// car's indicators. There is no automatic or curvature-based signalling to
  /// turn it ON: the player is responsible for that, just like a real driving
  /// exam. ([_updateSignalAutoCancel] runs first and may have cleared it.)
  void _readManualSignals() {
    final sig = InputState.instance.turnSignal;
    setLeftIndicator(sig < 0);
    setRightIndicator(sig > 0);
  }

  /// True once a bend in the armed blinker's direction is being driven through,
  /// until the road straightens again (then the blinker self-cancels).
  bool _turnUnderway = false;

  /// Self-cancel the blinker once a turn in its signalled direction has been
  /// driven THROUGH and the road has straightened again — the digital version
  /// of a steering wheel snapping the indicator stalk back off. Only the OFF is
  /// automatic; arming the blinker stays manual. Reads the heading change a
  /// short distance ahead on the current spline, so it keys off the geometry the
  /// car is actually driving (a parallel lane-change has no bend → never fires).
  void _updateSignalAutoCancel() {
    final sig = InputState.instance.turnSignal;
    final s = spline;
    if (sig == 0 || s == null) {
      _turnUnderway = false;
      return;
    }
    final tAhead =
        (currentT + kSignalCancelLookahead / s.totalLength).clamp(0.0, 1.0);
    final curve = normaliseAngle(s.angleAt(tAhead) - s.angleAt(currentT));
    final intoTurn = sig < 0
        ? curve < -kSignalCancelEnterCurve
        : curve > kSignalCancelEnterCurve;
    if (intoTurn) {
      _turnUnderway = true;
    } else if (_turnUnderway && curve.abs() < kSignalCancelExitCurve) {
      cancelSignalForCompletedManeuver(sig); // turn in [sig]'s direction is done
      _turnUnderway = false;
    }
  }

  /// Self-cancel the blinker now that the maneuver it was armed for is finished —
  /// a turn driven through (the curvature detector above) or a lane-change/merge
  /// that just COMMITTED (the haptic-click moment in [_updateLaneChange]). [dir]
  /// is that maneuver's direction (-1 left / +1 right); only a blinker armed the
  /// SAME way is cleared, so a wrong-way signal is left for the player. This is
  /// the one place the blinker turns itself off.
  void cancelSignalForCompletedManeuver(int dir) {
    if (InputState.instance.turnSignal == dir) InputState.instance.clearSignal();
  }

  /// At a committed lane change toward [dir] (-1 left / +1 right): if the
  /// matching blinker was armed, self-cancel it (the move is done); if it WASN'T,
  /// that's a "changed lanes without signalling" fault. Global — fires for every
  /// lane change / corridor merge on any tile (a universal commit, not per-tile).
  void _gradeLaneChangeCommit(int dir) {
    if (InputState.instance.turnSignal == dir) {
      InputState.instance.clearSignal(); // signalled → self-cancel (stalk snap-back)
    } else {
      GameBus.instance.emit(LaneChangeWithoutSignalEvent(speed: speed));
    }
  }

  /// Net turn direction of [branch] from its overall heading change: -1 left,
  /// +1 right, 0 if effectively straight (a through fork, not a turn).
  int _branchTurnSign(Spline branch) {
    final net = normaliseAngle(branch.angleAt(1.0) - branch.angleAt(0.0));
    if (net < -kTurnGradeMinAngle) return -1;
    if (net > kTurnGradeMinAngle) return 1;
    return 0;
  }

  /// At a committed TURN onto [branch]: if it actually turns and the matching
  /// blinker isn't armed, that's a "turned without signalling" fault. Global —
  /// fires for every commanded turn on any tile. (The blinker's own self-cancel
  /// happens later, via the curvature detector, once the turn is driven through,
  /// so here the blinker still reflects what the player set on the approach.)
  void _gradeTurnSignal(Spline branch) {
    final dir = _branchTurnSign(branch);
    if (dir != 0 && InputState.instance.turnSignal != dir) {
      GameBus.instance.emit(TurnWithoutSignalEvent(speed: speed));
    }
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
