import 'dart:async';
import 'package:flame/components.dart';
import '../core/game_bus.dart';
import '../tiles/tile_manager.dart';
import 'exam_error.dart';
import 'exam_error_log.dart';

/// Turns every rule-break trigger on the [GameBus] into a recorded
/// [ExamError] with context (tile, commanded maneuver, speed).
///
/// Purely observational: it never affects the fail model — game-over flow is
/// owned by RuleValidator. It is the data layer behind the two non-crash fault
/// streams the player reviews separately: failed scenario *tasks*
/// ([ScenarioTaskFailedEvent] + road-blocking) and *unsafe* driving (the NPC
/// "!" reactions). A crash is recorded too, as the terminal event.
class ExamErrorRecorder extends Component {
  ExamErrorRecorder({required this.tileManager, ExamErrorLog? log})
      : _log = log ?? ExamErrorLog.instance;

  final TileManager tileManager;
  final ExamErrorLog _log;

  final List<StreamSubscription<GameEvent>> _subs = [];

  /// Bus generation this recorder belongs to; once stale it's a leaked listener
  /// from a restarted game and must not record (else one event is logged once
  /// per leaked recorder — the "12 stop faults for one miss" bug). See [GameBus].
  int _gen = 0;

  @override
  void onMount() {
    super.onMount();
    _gen = GameBus.instance.generation;
    _log.startRun();

    // Failed scenario tasks — RuleValidator does the context-aware grading and
    // names the rule when it can; we record its verdict (kind + reason).
    _subs.add(GameBus.instance.on<ScenarioTaskFailedEvent>().listen((e) =>
        _record(e.kind ?? ExamErrorType.scenarioFault,
            speed: e.speed, detail: e.reason)));
    _subs.add(GameBus.instance.on<RoadBlockingEvent>().listen((e) => _record(
        ExamErrorType.roadBlocking,
        detail: 'stood still ${e.duration.toStringAsFixed(1)}s')));

    // Forced a pedestrian crossing (drove through without yielding). Logged as a
    // failed-to-yield fault; hitting the pedestrian is a separate collision.
    _subs.add(GameBus.instance.on<PedestrianYieldViolationEvent>().listen((e) =>
        _record(ExamErrorType.failedToYield,
            speed: e.speedAtLine, detail: 'pedestrian')));

    // Unsafe driving — an NPC threw the "!" because the player forced a hard
    // brake (cut-off). Logged independently of any scenario verdict.
    _subs.add(GameBus.instance.on<DriverReactionEvent>().listen(
        (e) => _record(ExamErrorType.cutOff, detail: e.reaction.name)));

    // Manoeuvred without signalling — detected globally at the commit (PlayerCar),
    // not by any tile scenario. Recorded straight through, like the cut-off above.
    _subs.add(GameBus.instance.on<LaneChangeWithoutSignalEvent>().listen((e) =>
        _record(ExamErrorType.laneChangeWithoutSignal, speed: e.speed)));
    _subs.add(GameBus.instance.on<TurnWithoutSignalEvent>().listen((e) =>
        _record(ExamErrorType.turnWithoutSignal, speed: e.speed)));

    _subs.add(GameBus.instance.on<CollisionEvent>().listen(
        (e) => _record(ExamErrorType.collision, detail: e.otherType)));
  }

  @override
  void onRemove() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.onRemove();
  }

  void _record(ExamErrorType type, {double? speed, String? detail}) {
    if (_gen != GameBus.instance.generation) return; // leaked recorder
    final tile = tileManager.activeTile;
    _log.record(ExamError(
      type: type,
      runId: _log.currentRunId,
      at: DateTime.now(),
      tileType: tile?.tileType.name ?? 'unknown',
      maneuver: tile?.commandedManeuver,
      speed: speed,
      detail: detail,
    ));
  }
}
