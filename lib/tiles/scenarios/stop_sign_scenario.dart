import 'scenario_base.dart';

/// US all-way STOP. Unlike [YieldScenario] (European priority-to-the-right,
/// where rolling through a clear junction is legal), the player must come to a
/// **complete stop** at the line — every time, even with no conflicting
/// traffic. That mandatory stop is the whole lesson, so the pass gate is
/// "stopped fully and then cleared safely", and a rolling stop fails the task.
///
/// The tile ([IntersectionTile] in all-way-stop control) owns the windowed
/// detection and emits [StopSignViolationEvent] when no full stop occurred;
/// this scenario only records the outcome. Failing is non-fatal — only a crash
/// ends the run — so a rolling stop becomes a logged fault for later review.
class StopSignScenario extends ScenarioBase {
  bool _violated = false;
  bool _passed = false;

  @override
  void onCollision(String otherType) {
    if (!_passed) {
      result = ScenarioResult.failed('Crashed into a $otherType!');
    }
  }

  @override
  void onStopSignViolation(double minSpeed) {
    _violated = true;
    result = ScenarioResult.failed(
        'Rolling stop — you slowed to ${minSpeed.toStringAsFixed(0)} but never '
        'came to a complete stop at the sign.');
  }

  /// An all-way stop still requires yielding after the stop; pulling out in
  /// front of traffic with priority is a fault too.
  @override
  void onYieldViolation(double speedAtLine) {
    _violated = true;
    result = ScenarioResult.failed(
        'Pulled out without giving way — another driver had the right of way.');
  }

  @override
  void onSafelyCleared() {
    // No violation fired means the tile credited a full stop — pass.
    if (!_violated && result.status == ScenarioStatus.ongoing) {
      _passed = true;
      result = const ScenarioResult.passed();
    }
  }

  @override
  void reset() {
    super.reset();
    _violated = false;
    _passed = false;
  }
}
