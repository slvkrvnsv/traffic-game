/// The result of a scenario's ongoing evaluation.
enum ScenarioStatus { ongoing, passed, failed }

class ScenarioResult {
  const ScenarioResult.ongoing()
      : status = ScenarioStatus.ongoing,
        reason = null;
  const ScenarioResult.passed()
      : status = ScenarioStatus.passed,
        reason = null;
  const ScenarioResult.failed(String this.reason)
      : status = ScenarioStatus.failed;

  final ScenarioStatus status;
  final String? reason;
}

/// Abstract base for all tile scenarios.
///
/// A scenario defines the traffic rule the player must obey on a given tile.
/// It receives game events and updates its own state; TileManager reads [result].
abstract class ScenarioBase {
  ScenarioResult result = const ScenarioResult.ongoing();

  /// Called every frame by the tile.
  void update(double dt) {}

  /// Called by RuleValidator with a rule event.
  void onCollision(String otherType) {}
  void onYieldViolation(double speedAtLine) {}
  void onStopSignViolation(double minSpeed) {}
  void onRedLightViolation() {}
  void onPlayerPassedYieldLine(double speed) {}

  /// Called by the tile once the player has cleared its conflict zone without
  /// a violation. Scenarios use this to report [ScenarioStatus.passed].
  void onSafelyCleared() {}

  /// Reset for reuse (test mode loops same tile).
  void reset() {
    result = const ScenarioResult.ongoing();
  }
}
