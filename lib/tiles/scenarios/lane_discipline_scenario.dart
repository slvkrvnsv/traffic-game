import 'scenario_base.dart';
import 'traffic_light_scenario.dart';

/// The graded rule for the 2-lane traffic-light intersection ([IntersectionLightTile]).
///
/// It IS a traffic light — stop on red, permissive-left gives way to oncoming,
/// don't block the box, yield to pedestrians — so it reuses every
/// [TrafficLightScenario] verdict, and adds ONE lesson on top: **lane
/// discipline**. The game commands a maneuver AND a lane change (always a task);
/// being in the wrong lane for the maneuver at the box — turning left from a
/// through/right lane, or going straight from a left-turn-only lane — is a
/// logged fault. Non-fatal like every other non-crash mistake.
class LaneDisciplineScenario extends TrafficLightScenario {
  // Any of the three lane-discipline faults (wrong lane / wrong maneuver / wrong
  // exit lane) latches this, so a clean clear no longer counts as a pass. Kept
  // distinct from the harder light faults — the reason names the lane error.
  bool _laneFaulted = false;

  void _failLane(String reason) {
    _laneFaulted = true;
    if (result.status == ScenarioStatus.ongoing) {
      result = ScenarioResult.failed(reason);
    }
  }

  @override
  void onWrongLane() => _failLane(
      'Wrong lane for the turn — you were in the wrong lane through the intersection.');

  @override
  void onMissedTurn() => _failLane(
      'Missed your turn — you made a different move than the one you were told to.');

  @override
  void onWrongExitLane() => _failLane(
      'Turn into the nearest lane — you turned into the far lane instead of the closest one.');

  @override
  void onSafelyCleared() {
    // A lane fault already failed the run; otherwise defer to the light rules
    // (a clean green/yellow clear in the correct lane is a pass).
    if (_laneFaulted) return;
    super.onSafelyCleared();
  }

  @override
  void reset() {
    super.reset();
    _laneFaulted = false;
  }
}
