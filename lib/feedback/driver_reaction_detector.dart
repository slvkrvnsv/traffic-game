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
    for (final npc in tileManager.allNpcs) {
      final state = _states[npc] ??= _ReactState();
      if (state.cooldown > 0) state.cooldown -= dt;

      final hardNow = _isForcedHardBrake(npc);
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
  bool _isForcedHardBrake(NpcCar npc) {
    if (npc.speed < kReactMinSpeed) return false;
    if (npc.position.distanceTo(playerCar.position) > kReactMaxDistance) {
      return false;
    }
    final gap = _playerGapAhead(npc);
    if (gap == null) return false;
    return isForcedHardBrake(npc.speed, gap);
  }

  /// Pure discriminator: does forcing the NPC to a stop within [gap] (at
  /// [speed]) demand harder braking than steady following ever needs? Measured
  /// against the planning distance `brakeDist = gap − kNpcStandingGap`, so
  /// equilibrium following sits at exactly 1×[kNpcBrakeDecel] and only a genuine
  /// cut-in / brake-check pushes a_req past the multiplier. Static + pure so the
  /// correctness boundary can be unit-tested directly.
  static bool isForcedHardBrake(double speed, double gap) {
    final brakeDist = math.max(gap - kNpcStandingGap, 1.0);
    final aReq = (speed * speed) / (2 * brakeDist);
    return aReq > kReactHardBrakeMultiplier * kNpcBrakeDecel;
  }

  /// Bumper-to-bumper gap to the player if the player is ahead of [npc] and in
  /// the same lane, else null. Mirrors [TileBase] lead-car geometry.
  double? _playerGapAhead(NpcCar npc) {
    final forward = Vector2(math.cos(npc.angle), math.sin(npc.angle));
    final delta = playerCar.position - npc.position;
    final fwd = delta.dot(forward);
    if (fwd < kCarLength * 0.5) return null; // behind or overlapping
    final lateral = (delta - forward * fwd).length;
    if (lateral > kCarWidth * 1.8) return null; // different lane
    return (fwd - kCarLength).clamp(0.0, double.infinity);
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
