import '../../core/constants.dart';
import 'scenario_base.dart';

/// Player must slow below [kYieldSpeedThreshold] before the yield line
/// and may only proceed when the intersection is clear.
class YieldScenario extends ScenarioBase {
  bool _slowedAtLine = false;
  bool _passed = false;

  @override
  void onCollision(String otherType) {
    if (!_passed) {
      result = ScenarioResult.failed('Crashed into a $otherType!');
    }
  }

  @override
  void onYieldViolation(double speedAtLine) {
    result = ScenarioResult.failed(
        'Failed to yield — you were going ${speedAtLine.toStringAsFixed(0)} when you should have slowed down.');
  }

  @override
  void onPlayerPassedYieldLine(double speed) {
    if (speed <= kYieldSpeedThreshold) {
      _slowedAtLine = true;
    }
  }

  @override
  void onSafelyCleared() {
    if (_slowedAtLine && result.status == ScenarioStatus.ongoing) {
      _passed = true;
      result = const ScenarioResult.passed();
    }
  }

  @override
  void reset() {
    super.reset();
    _slowedAtLine = false;
    _passed = false;
  }
}
