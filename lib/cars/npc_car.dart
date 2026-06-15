import '../npc/npc_brain.dart';
import 'car_base.dart';

/// An NPC car whose speed is driven by [NpcBrain].
/// World position is handled by [SplineFollower.worldOffset] — no separate offset needed.
class NpcCar extends CarBase {
  NpcCar({
    required super.definition,
    required this.profileSpeed,
    super.priority = 5,
  }) : brain = NpcBrain();

  final NpcBrain brain;
  final double profileSpeed;

  /// Index of the path in the tile's [npcPaths] list this NPC was assigned to.
  int laneIndex = 0;

  /// Distance travelled *past* the current spline's end this frame. TileManager
  /// reads this to carry the NPC seamlessly onto the next tile's lane.
  double pendingOverflow = 0.0;

  NpcCar? leadCar;

  @override
  void onMount() {
    super.onMount();
    brain.init(this);
  }

  /// Slightly stronger natural deceleration than the player for realistic NPC
  /// engine-braking behaviour.
  @override
  double get rollingDrag => 90.0;

  @override
  void update(double dt) {
    brain.update(dt, this);
    targetSpeed = brain.desiredSpeed;
    // Brake (instead of coasting on rolling drag) whenever we must shed speed
    // to reach the target. A small deadband avoids jitter while keeping stops
    // precise, so cars halt right on their line instead of rolling past it.
    isBraking = brain.desiredSpeed < speed - 6.0;
    super.update(dt);
  }

  @override
  void onSplineEnd(double overflow) {
    // Record how far past the seam we rolled this frame so TileManager can
    // carry it onto the next tile's lane. Crucially we keep [speed] (momentum):
    // braking here would make through-traffic stutter to a halt at every tile
    // boundary. NPCs with no continuation are stopped/removed by TileManager.
    pendingOverflow = overflow;
  }

  bool get isAtSplineEnd => hasReachedEnd;

  double distanceTo(NpcCar other) => position.distanceTo(other.position);
}
