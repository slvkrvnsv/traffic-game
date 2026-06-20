/// Abstract base for all NPC brain states.
abstract class NpcState {
  /// Called once when the brain transitions into this state.
  void enter() {}

  /// Called every frame. Returns the desired speed.
  double update(double dt, NpcSensors sensors);

  /// Called once when the brain transitions away from this state.
  void exit() {}
}

/// Sensor snapshot passed to each state every update.
class NpcSensors {
  NpcSensors({
    required this.profileSpeed,
    required this.currentSpeed,
    required this.currentT,
    required this.leadCarDistance,   // units to bumper of car ahead (null = no car)
    required this.intersectionRuleActive, // true if tile has an active yield/stop rule
    required this.hasRightOfWay,     // true = NPC may proceed; false = must yield
    required this.isRedLight,        // true if NPC is at a red light
    required this.distanceToTurnSignal, // units remaining before indicator should start
    required this.isTurning,         // true if this NPC's spline includes a turn
  });

  final double profileSpeed;
  final double currentSpeed;
  final double currentT;
  final double? leadCarDistance;
  final bool intersectionRuleActive;
  final bool hasRightOfWay;
  final bool isRedLight;
  final double distanceToTurnSignal;
  final bool isTurning;
}
