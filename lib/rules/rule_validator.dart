import 'dart:async';
import 'package:flame/components.dart';
import '../core/game_bus.dart';
import '../tiles/scenarios/scenario_base.dart';
import 'exam_error.dart';

/// Bridges [GameBus] rule events to the *currently active* tile's
/// [ScenarioBase]. Each tile owns the rule the player must obey there
/// (e.g. a 4-way intersection uses StopSignScenario), so violations are always
/// evaluated against the scenario for the tile the player is actually on.
///
/// The fail model is deliberately narrow: **only a crash ends the run**
/// ([CollisionEvent] → [GameOverEvent]). Every other mistake is non-fatal — a
/// failed scenario task becomes a [ScenarioTaskFailedEvent] (recorded for the
/// "how you should've done it" review), and road-blocking / NPC reactions are
/// logged elsewhere. This component never game-overs on a rule break.
///
/// A [Component] so its bus subscriptions live and die with the [GameWorld]
/// that owns it — restarting the game can never stack up stale listeners.
class RuleValidator extends Component {
  /// Supplies the scenario for the player's current tile. Bound by GameWorld.
  ScenarioBase? Function()? _scenarioSource;

  /// The scenario instance we last emitted a failure for. Each tile owns its
  /// own scenario instance, so identity comparison edge-detects the failure —
  /// further events after a scenario has failed don't re-record it.
  ScenarioBase? _lastFailed;

  final List<StreamSubscription<GameEvent>> _subs = [];

  /// Bus generation this validator belongs to; once it's stale (a newer game
  /// started) this is a leaked listener and must not act — see [GameBus].
  int _gen = 0;
  bool get _stale => _gen != GameBus.instance.generation;

  void bindScenarioSource(ScenarioBase? Function() source) {
    _scenarioSource = source;
  }

  ScenarioBase? get _activeScenario =>
      _stale ? null : _scenarioSource?.call();

  @override
  void onMount() {
    super.onMount();
    _gen = GameBus.instance.generation;

    // Collisions are unconditional and tile-independent — fail immediately.
    _subs.add(GameBus.instance.on<CollisionEvent>().listen((e) {
      if (_stale) return; // leaked listener from a restarted game
      final reason = e.otherType == 'pedestrian'
          ? 'You hit a pedestrian!'
          : 'You crashed into another car!';
      GameBus.instance.emit(GameOverEvent(reason: reason));
    }));

    _subs.add(GameBus.instance.on<YieldViolationEvent>().listen((e) {
      final scenario = _activeScenario;
      scenario?.onYieldViolation(e.speedAtLine);
      _checkResult(scenario,
          kind: ExamErrorType.failedToYield, speed: e.speedAtLine);
    }));
    _subs.add(GameBus.instance.on<StopSignViolationEvent>().listen((e) {
      final scenario = _activeScenario;
      scenario?.onStopSignViolation(e.minSpeedObserved);
      _checkResult(scenario,
          kind: ExamErrorType.stopSignViolation, speed: e.minSpeedObserved);
    }));
    _subs.add(GameBus.instance.on<RedLightViolationEvent>().listen((_) {
      final scenario = _activeScenario;
      scenario?.onRedLightViolation();
      _checkResult(scenario, kind: ExamErrorType.redLightViolation);
    }));

    // An NPC reacting to a player cut-off is bubble-only feedback on most tiles;
    // a graded merge routes it to its scenario, which fails only if the player
    // was actually the merging car. The cut-off itself is logged as unsafe
    // driving by the recorder; here it can additionally fail the merge *task*.
    _subs.add(GameBus.instance.on<DriverReactionEvent>().listen((_) {
      final scenario = _activeScenario;
      scenario?.onDriverReaction();
      _checkResult(scenario);
    }));

    // Road-blocking is no longer fatal — the recorder logs it as a fault. (It
    // stays context-gated by the detector, so it only fires on a real block.)
  }

  @override
  void onRemove() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.onRemove();
  }

  /// Emit a [ScenarioTaskFailedEvent] the first time [scenario] reaches the
  /// failed state — never a game-over (only a crash does that). Edge-detected
  /// by scenario identity so post-failure events don't double-record.
  void _checkResult(ScenarioBase? scenario,
      {ExamErrorType? kind, double? speed}) {
    if (scenario == null) return;
    if (scenario.result.status != ScenarioStatus.failed) return;
    if (identical(scenario, _lastFailed)) return;
    _lastFailed = scenario;
    GameBus.instance.emit(ScenarioTaskFailedEvent(
      reason: scenario.result.reason ?? 'Failed the maneuver',
      kind: kind,
      speed: speed,
    ));
  }
}
