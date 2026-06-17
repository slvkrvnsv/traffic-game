import 'scenario_base.dart';

/// The "merge left" rule (2→1 lane drop).
///
/// Grading is **passive and lane-scoped**: it only applies while the player is
/// actually in the ending (right) lane and merging. If they sit in the through
/// (left) lane they have priority — nothing is tested ("just go"). The merge
/// tile sets [playerIsMerging] every frame from the player's current lane.
///
/// The fault is forcing through traffic to brake hard, which the existing
/// driver-reaction detector already pinpoints (a_req vs brakeDist on the rising
/// edge); on this tile, while merging, that *is* an unsafe merge.
class MergeScenario extends ScenarioBase {
  /// True while the player occupies the merging lane (set by the tile). The
  /// fault only counts when this is true — a player in the through lane can't
  /// fail a merge they aren't making.
  bool playerIsMerging = false;

  bool _passed = false;

  @override
  void onCollision(String otherType) {
    if (!_passed) {
      result = ScenarioResult.failed('Crashed into a $otherType!');
    }
  }

  @override
  void onDriverReaction() {
    // Only the merging car can fault here; a through-lane player has priority.
    if (playerIsMerging && result.status == ScenarioStatus.ongoing) {
      result = ScenarioResult.failed(
          'Unsafe merge — you cut off a car instead of yielding to through traffic.');
    }
  }

  @override
  void onSafelyCleared() {
    if (result.status == ScenarioStatus.ongoing) {
      _passed = true;
      result = const ScenarioResult.passed();
    }
  }

  @override
  void reset() {
    super.reset();
    _passed = false;
    playerIsMerging = false;
  }
}
