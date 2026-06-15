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
/// owned by RuleValidator. This is the data layer a future scoring / lives /
/// exam-results feature will read from.
class ExamErrorRecorder extends Component {
  ExamErrorRecorder({required this.tileManager, ExamErrorLog? log})
      : _log = log ?? ExamErrorLog.instance;

  final TileManager tileManager;
  final ExamErrorLog _log;

  final List<StreamSubscription<GameEvent>> _subs = [];

  @override
  void onMount() {
    super.onMount();
    _log.startRun();

    _subs.add(GameBus.instance.on<YieldViolationEvent>().listen(
        (e) => _record(ExamErrorType.failedToYield, speed: e.speedAtLine)));
    _subs.add(GameBus.instance.on<StopSignViolationEvent>().listen((e) =>
        _record(ExamErrorType.stopSignViolation, speed: e.minSpeedObserved)));
    _subs.add(GameBus.instance.on<RedLightViolationEvent>().listen(
        (_) => _record(ExamErrorType.redLightViolation)));
    _subs.add(GameBus.instance.on<RoadBlockingEvent>().listen((e) => _record(
        ExamErrorType.roadBlocking,
        detail: 'stood still ${e.duration.toStringAsFixed(1)}s')));
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
