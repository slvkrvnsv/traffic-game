import 'scenario_base.dart';

/// Signalised 4-way intersection. The lesson is signal compliance: stop on red,
/// go on green. Crossing the stop line on a red is the fault — the tile detects
/// it ([IntersectionTile] in traffic-light control) and emits
/// [RedLightViolationEvent]; this scenario only records the outcome.
///
/// Unlike [StopSignScenario] (a mandatory *complete* stop every time), a clean
/// run-through on green is a pass here — no stop required. Like every non-crash
/// fault the red-light violation is non-fatal: a logged exam error, not a
/// game-over. (Running a red typically T-bones cross traffic that has the green,
/// and *that* collision is what ends the run.)
class TrafficLightScenario extends ScenarioBase {
  bool _violated = false;
  bool _passed = false;

  @override
  void onCollision(String otherType) {
    if (!_passed) {
      result = ScenarioResult.failed('Crashed into a $otherType!');
    }
  }

  @override
  void onRedLightViolation() {
    _violated = true;
    result =
        const ScenarioResult.failed('Ran a red light — you crossed on red.');
  }

  /// A permissive left turn must give way to oncoming through-traffic. Turning
  /// across an oncoming car that had the right of way is a fail-to-yield (the
  /// tile detects it; this only records it). Non-fatal — a logged fault — unless
  /// the cut-off becomes an actual collision, which ends the run.
  @override
  void onYieldViolation(double speedAtLine) {
    _violated = true;
    result = const ScenarioResult.failed(
        'Turned left without yielding — oncoming traffic had the right of way.');
  }

  /// Entering the box without room to clear it — left stuck inside, blocking
  /// cross traffic ("don't block the box").
  @override
  void onBlockedIntersection() {
    _violated = true;
    result = const ScenarioResult.failed(
        'Blocked the intersection — you stopped in the box with no room to clear.');
  }

  @override
  void onSafelyCleared() {
    // No violation fired means the player cleared on green/yellow — pass.
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
