import 'scenario_base.dart';

/// No special rule — just drive through without crashing.
/// Any collision still fails; idling still annoys NPCs.
class FreeDriveScenario extends ScenarioBase {
  @override
  void onCollision(String otherType) {
    result = ScenarioResult.failed('Crashed into a $otherType!');
  }
}
