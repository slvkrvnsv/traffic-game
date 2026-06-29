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

  /// Player entered the box on a yellow they had room to stop for comfortably.
  void onYellowRun() {}

  /// Player stopped with the nose past the stop line on red (over the line).
  void onStopLineViolation() {}

  /// Player went on green before cross traffic had finished clearing the box.
  void onGunGreen() {}

  void onBlockedIntersection() {}

  /// Player was in the wrong lane for the commanded maneuver at a multi-lane
  /// intersection (e.g. turned left from a through-only lane). A logged fault.
  void onWrongLane() {}

  /// Player missed the turn — ended up somewhere other than the instruction
  /// (drove straight, or took the other turn, instead of the commanded one). A
  /// logged fault.
  void onMissedTurn() {}

  /// Player turned into the far lane of the target road instead of the nearest.
  void onWrongExitLane() {}

  void onPlayerPassedYieldLine(double speed) {}

  /// Called when an NPC reacted to the player forcing it into a hard brake
  /// (a cut-off). Most scenarios ignore it — the visible bubble is feedback
  /// enough — but a graded merge treats it as a fault (when the player is the
  /// one merging).
  void onDriverReaction() {}

  /// Called by the tile once the player has cleared its conflict zone without
  /// a violation. Scenarios use this to report [ScenarioStatus.passed].
  void onSafelyCleared() {}

  /// Reset for reuse (test mode loops same tile).
  void reset() {
    result = const ScenarioResult.ongoing();
  }
}
