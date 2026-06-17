import 'dart:async';
import 'package:flame/components.dart';
import '../core/game_bus.dart';
import '../tiles/scenarios/scenario_base.dart';

/// Bridges [GameBus] rule events to the *currently active* tile's
/// [ScenarioBase]. Each tile owns the rule the player must obey there
/// (e.g. a 4-way intersection uses YieldScenario), so violations are always
/// evaluated against the scenario for the tile the player is actually on.
///
/// When a scenario reports failure, this emits [GameOverEvent].
///
/// A [Component] so its bus subscriptions live and die with the [GameWorld]
/// that owns it — restarting the game can never stack up stale listeners.
class RuleValidator extends Component {
  /// Supplies the scenario for the player's current tile. Bound by GameWorld.
  ScenarioBase? Function()? _scenarioSource;

  final List<StreamSubscription<GameEvent>> _subs = [];

  void bindScenarioSource(ScenarioBase? Function() source) {
    _scenarioSource = source;
  }

  ScenarioBase? get _activeScenario => _scenarioSource?.call();

  @override
  void onMount() {
    super.onMount();

    // Collisions are unconditional and tile-independent — fail immediately.
    _subs.add(GameBus.instance.on<CollisionEvent>().listen((e) {
      final reason = e.otherType == 'pedestrian'
          ? 'You hit a pedestrian!'
          : 'You crashed into another car!';
      GameBus.instance.emit(GameOverEvent(reason: reason));
    }));

    _subs.add(GameBus.instance.on<YieldViolationEvent>().listen((e) {
      final scenario = _activeScenario;
      scenario?.onYieldViolation(e.speedAtLine);
      _checkResult(scenario);
    }));
    _subs.add(GameBus.instance.on<StopSignViolationEvent>().listen((e) {
      final scenario = _activeScenario;
      scenario?.onStopSignViolation(e.minSpeedObserved);
      _checkResult(scenario);
    }));
    _subs.add(GameBus.instance.on<RedLightViolationEvent>().listen((_) {
      final scenario = _activeScenario;
      scenario?.onRedLightViolation();
      _checkResult(scenario);
    }));

    // An NPC reacting to a player cut-off is bubble-only feedback on most tiles;
    // a graded merge routes it to its scenario, which fails only if the player
    // was actually the merging car. Scenarios that don't override it ignore it.
    _subs.add(GameBus.instance.on<DriverReactionEvent>().listen((_) {
      final scenario = _activeScenario;
      scenario?.onDriverReaction();
      _checkResult(scenario);
    }));

    // Blocking the road is a universal rule (already context-gated by the
    // detector), so it fails immediately and tile-independently like a crash.
    _subs.add(GameBus.instance.on<RoadBlockingEvent>().listen((_) {
      GameBus.instance.emit(GameOverEvent(
        reason: 'You blocked the road — keep moving when the way is clear.',
      ));
    }));
  }

  @override
  void onRemove() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.onRemove();
  }

  void _checkResult(ScenarioBase? scenario) {
    final result = scenario?.result;
    if (result?.status == ScenarioStatus.failed) {
      GameBus.instance.emit(GameOverEvent(reason: result!.reason ?? 'Game over'));
    }
  }
}
