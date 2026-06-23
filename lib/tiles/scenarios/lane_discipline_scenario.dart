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
  bool _wrongLane = false;

  @override
  void onWrongLane() {
    // Latch a violation so a clean clear no longer counts as a pass, but keep it
    // distinct from the harder light faults — the reason names the lane error.
    _wrongLane = true;
    if (result.status == ScenarioStatus.ongoing) {
      result = const ScenarioResult.failed(
          'Wrong lane for the turn — you were in the wrong lane through the intersection.');
    }
  }

  @override
  void onSafelyCleared() {
    // A lane fault already failed the run; otherwise defer to the light rules
    // (a clean green/yellow clear in the correct lane is a pass).
    if (_wrongLane) return;
    super.onSafelyCleared();
  }

  @override
  void reset() {
    super.reset();
    _wrongLane = false;
  }
}
