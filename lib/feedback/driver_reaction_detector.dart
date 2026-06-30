import 'dart:math' as math;
import 'package:flame/components.dart';
import '../core/constants.dart';
import '../core/game_bus.dart';
import '../cars/npc_car.dart';
import '../cars/player_car.dart';
import '../tiles/tile_manager.dart';
import 'driver_reaction.dart';
import 'reaction_bubble.dart';

/// Per-NPC reaction bookkeeping (rising-edge + cooldown). Held in a weak
/// [Expando] so culled NPCs drop out automatically — no manual cleanup.
class _ReactState {
  double cooldown = 0.0;
  bool hardBraking = false;

  /// How long the player has *continuously* been ahead in this NPC's lane. A
  /// genuine cut-off is a fresh intrusion (small value); a car the player has
  /// been ahead of all along is just catching up (large value → not a cut-off).
  double timeInPath = 0.0;

  /// The spline this NPC was on last frame. A change means it was re-assigned —
  /// a cross-seam carry (or first sight after spawn) — which teleports its
  /// geometry discontinuously; we re-baseline that frame rather than mistake the
  /// player suddenly ahead on the new spline for a fresh cut-in.
  Object? lastSpline;
}

/// Detects when the player forces an NPC into a hard brake (e.g. cutting in on
/// an overtake) and triggers that driver's reaction bubble.
///
/// Sibling of [ViolationDetector] and purely additive: it reads positions and
/// gaps itself (no coupling into [NpcBrain]), spawns the bubble directly (it
/// holds the live NPC), and emits a data-only [DriverReactionEvent] for future
/// scoring. The key to not feeling cheap is the discriminator — it fires on the
/// *rising edge* of forced hard braking, not on ordinary following.
class DriverReactionDetector extends Component {
  DriverReactionDetector({
    required this.playerCar,
    required this.tileManager,
    required this.world,
  });

  final PlayerCar playerCar;
  final TileManager tileManager;
  final World world;

  final Expando<_ReactState> _states = Expando<_ReactState>();

  @override
  void update(double dt) {
    // At an intersection the right-of-way (fail-to-yield) is graded by the
    // intersection tile itself; the generic cut-off detector only adds false
    // positives there — most visibly a car that streams in and barrels up
    // behind the player while it waits its turn (a fresh NPC defeats the
    // per-NPC freshness gate). The tile decides when to suppress it (the
    // all-way stop always; the multi-lane light only near/in the box).
    if (tileManager.activeTile?.suppressDriverReactions ?? false) {
      return;
    }
    for (final npc in tileManager.allNpcs) {
      final state = _states[npc] ??= _ReactState();
      if (state.cooldown > 0) state.cooldown -= dt;

      // A spline re-assignment (a cross-seam carry, or first sight after spawn)
      // moves the NPC's geometry discontinuously this frame: the player can jump
      // from "not in this lane" to "right ahead" with no motion the player made.
      // Re-baseline (not fresh, already-braking) so the teleport frame — and the
      // first frame after it — can't fire a phantom "player cut me off" against a
      // car that simply streamed in behind a player who did nothing.
      if (!identical(npc.spline, state.lastSpline)) {
        state.lastSpline = npc.spline;
        state.timeInPath = kReactCutInWindowSeconds + 1.0; // not a fresh intrusion
        state.hardBraking = true; // no rising edge on the next frame either
        continue;
      }

      // Track how long the player has been *settled* ahead in this lane, to
      // tell a fresh cut-in/merge apart from a car catching up to a player
      // that's been ahead all along (the rear-approach false positive). Only
      // accrue while the player is squarely in the lane; while it's still
      // moving laterally across into it (a merge/cut-in) the timer stays at 0,
      // so the intrusion reads as fresh and merge grading still fires. NOTE: a
      // review finder flagged that `lateral` (projected off the NPC's straight
      // tangent) inflates on curves, which can defeat this gate on a bend — but
      // widening the threshold risks gating the merge cut-off (and merge grading
      // has no detector-path test), so the proper fix is a curve-aware lateral
      // (project against the NPC's spline), not a threshold nudge. Left tight.
      final info = _playerAheadInfo(npc);
      final settled = info != null && info.lateral < kCarWidth * 0.6;
      state.timeInPath = settled ? state.timeInPath + dt : 0.0;

      final hardNow = _isForcedHardBrake(npc, state.timeInPath);
      // Rising edge only: fire as the NPC is pushed into hard braking, once.
      if (hardNow && !state.hardBraking && state.cooldown <= 0) {
        _react(npc, DriverReaction.cutOff);
        state.cooldown = kReactCooldownSeconds;
      }
      state.hardBraking = hardNow;
    }
  }

  /// True when the player is the close obstacle ahead of [npc] in its lane and
  /// the deceleration the NPC needs to avoid the player exceeds the hard-brake
  /// threshold — i.e. the player cut in / brake-checked it.
  bool _isForcedHardBrake(NpcCar npc, double timeInPath) {
    if (npc.speed < kReactMinSpeed) return false;
    // A cut-off is an *active*, *fresh* same-lane intrusion by a moving player.
    // Guards against blaming the player for a brake it didn't cause:
    //  - a stopped / yielding player isn't cutting anyone off;
    //  - an NPC turning (or cross-traffic), heading diverging from the player's,
    //    is braking for its own path, not because the player cut in;
    //  - a car the player has been ahead of all along (timeInPath large) is
    //    just catching up / following — the player waiting at a stop while a
    //    fast car rolls up from behind is the classic false positive.
    if (playerCar.speed < kReactMinSpeed) return false;
    if (math.cos(playerCar.splineAngle - npc.angle) <
        math.cos(kReactMaxHeadingDelta)) {
      return false;
    }
    if (timeInPath > kReactCutInWindowSeconds) return false;
    if (npc.position.distanceTo(playerCar.position) > kReactMaxDistance) {
      return false;
    }
    final gap = _playerGapAhead(npc);
    if (gap == null) return false;
    // Closing speed, not the NPC's absolute speed: a player merging in at the
    // NPC's own pace forces no brake however tight the gap, so it can't fault.
    return isForcedHardBrake(npc.speed - playerCar.speed, gap);
  }

  /// Pure discriminator: does the NPC have to brake harder than its routine firm
  /// stop to avoid the player ahead? Uses the *closing* speed [closingSpeed] (how
  /// fast the NPC is overtaking the player), not the NPC's absolute speed — a
  /// player who merges in at the NPC's own speed forces NO braking (closing ≈ 0),
  /// however small the gap, which is exactly why tucking a couple of car-lengths
  /// ahead at matching speed is a normal merge, not a cut-off. Only a slower (or
  /// braking) player closes the gap, and only fast enough closing onto a tight
  /// `brakeDist = gap − kNpcStandingGap` pushes a_req past
  /// [kReactHardBrakeMultiplier]×[kNpcBrakeDecel] (~30% above the NPC's routine
  /// firm brake). Static + pure so the correctness boundary can be unit-tested.
  ///
  /// Deliberate trade-off: a tight cut-in at *matched* speed reads as safe here
  /// (closing ≈ 0) — correct, no brake was forced; if speeds then diverge even
  /// slightly the spike reappears, and an actual touch is caught by the collision
  /// path.
  static bool isForcedHardBrake(double closingSpeed, double gap) {
    if (closingSpeed <= 0) return false; // matching / pulling away — no brake forced
    final brakeDist = math.max(gap - kNpcStandingGap, 1.0);
    final aReq = (closingSpeed * closingSpeed) / (2 * brakeDist);
    return aReq > kReactHardBrakeMultiplier * kNpcBrakeDecel;
  }

  /// Bumper-to-bumper gap to the player if the player is ahead of [npc] and in
  /// the same lane, else null. Mirrors [TileBase] lead-car geometry.
  double? _playerGapAhead(NpcCar npc) => _playerAheadInfo(npc)?.gap;

  /// Gap *and* the player's lateral offset from this NPC's lane axis, if the
  /// player is ahead and within the lane, else null. The lateral lets the
  /// caller tell a player squarely settled in the lane (a rear-approach) from
  /// one still moving across into it (a merge / cut-in).
  ({double gap, double lateral})? _playerAheadInfo(NpcCar npc) {
    final forward = Vector2(math.cos(npc.angle), math.sin(npc.angle));
    final delta = playerCar.position - npc.position;
    final fwd = delta.dot(forward);
    if (fwd < kCarLength * 0.5) return null; // behind or overlapping
    final lateral = (delta - forward * fwd).length;
    if (lateral > kCarWidth * 1.8) return null; // different lane
    return (gap: (fwd - kCarLength).clamp(0.0, double.infinity), lateral: lateral);
  }

  void _react(NpcCar npc, DriverReaction reaction) {
    world.add(ReactionBubble(
      target: npc,
      player: playerCar,
      reaction: reaction,
    ));
    GameBus.instance.emit(DriverReactionEvent(
      reaction: reaction,
      worldX: npc.position.x,
      worldY: npc.position.y,
    ));
  }
}
