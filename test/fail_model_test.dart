import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/game_bus.dart';
import 'package:traffic_game/feedback/driver_reaction.dart';
import 'package:traffic_game/rules/exam_error.dart';
import 'package:traffic_game/rules/exam_error_log.dart';
import 'package:traffic_game/rules/rule_validator.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';
import 'package:traffic_game/tiles/scenarios/yield_scenario.dart';
import 'package:traffic_game/tiles/scenarios/merge_scenario.dart';

/// Locks in the fail model: a crash is the only game-over; every other mistake
/// is non-fatal and routed to one of the two review streams (failed scenario
/// tasks / unsafe driving).
void main() {
  group('ExamErrorType category split', () {
    test('faults, unsafe driving, and the crash land in distinct buckets', () {
      ExamErrorCategory cat(ExamErrorType t) => t.category;
      expect(cat(ExamErrorType.failedToYield), ExamErrorCategory.fault);
      expect(cat(ExamErrorType.stopSignViolation), ExamErrorCategory.fault);
      expect(cat(ExamErrorType.redLightViolation), ExamErrorCategory.fault);
      expect(cat(ExamErrorType.roadBlocking), ExamErrorCategory.fault);
      expect(cat(ExamErrorType.scenarioFault), ExamErrorCategory.fault);
      expect(cat(ExamErrorType.cutOff), ExamErrorCategory.unsafe);
      expect(cat(ExamErrorType.collision), ExamErrorCategory.crash);
    });
  });

  group('ExamErrorLog stream getters', () {
    test('currentRunFaults and currentRunUnsafe filter by category', () {
      final log = ExamErrorLog.instance..startRun();
      final run = log.currentRunId;
      ExamError mk(ExamErrorType t) =>
          ExamError(type: t, runId: run, at: DateTime.now(), tileType: 't');

      log.record(mk(ExamErrorType.failedToYield));
      log.record(mk(ExamErrorType.scenarioFault));
      log.record(mk(ExamErrorType.cutOff));
      log.record(mk(ExamErrorType.collision));

      expect(log.currentRunFaults.map((e) => e.type),
          [ExamErrorType.failedToYield, ExamErrorType.scenarioFault]);
      expect(log.currentRunUnsafe.map((e) => e.type), [ExamErrorType.cutOff]);
    });
  });

  group('RuleValidator fail model', () {
    late ScenarioBase scenario;
    late RuleValidator validator;
    late List<GameEvent> seen;
    late StreamSubscription<GameEvent> spy;

    setUp(() {
      scenario = YieldScenario();
      validator = RuleValidator()..bindScenarioSource(() => scenario);
      validator.onMount();
      seen = [];
      spy = GameBus.instance.stream.listen(seen.add);
    });

    tearDown(() async {
      await spy.cancel();
      validator.onRemove();
    });

    /// Emit on the bus and let the broadcast stream deliver before asserting.
    Future<void> emit(GameEvent e) async {
      GameBus.instance.emit(e);
      await pumpEventQueue();
    }

    test('a crash is the only game-over', () async {
      await emit(CollisionEvent(otherType: 'npc_car'));
      expect(seen.whereType<GameOverEvent>(), hasLength(1));
    });

    test('a failed scenario task emits ScenarioTaskFailedEvent, never a '
        'game-over', () async {
      await emit(YieldViolationEvent(speedAtLine: 90));
      expect(seen.whereType<GameOverEvent>(), isEmpty);
      final fail = seen.whereType<ScenarioTaskFailedEvent>().single;
      expect(fail.kind, ExamErrorType.failedToYield);
      expect(fail.speed, 90);
      expect(scenario.result.status, ScenarioStatus.failed);
    });

    test('the failure is edge-detected — repeat events do not re-emit',
        () async {
      await emit(YieldViolationEvent(speedAtLine: 90));
      await emit(YieldViolationEvent(speedAtLine: 70));
      expect(seen.whereType<ScenarioTaskFailedEvent>(), hasLength(1));
    });

    test('road-blocking is no longer a game-over', () async {
      await emit(RoadBlockingEvent(duration: 5));
      expect(seen.whereType<GameOverEvent>(), isEmpty);
    });

    test('an unsafe merge fails the task with no named kind (carries reason)',
        () async {
      scenario = MergeScenario()..playerIsMerging = true;
      await emit(DriverReactionEvent(
          reaction: DriverReaction.cutOff, worldX: 0, worldY: 0));
      final fail = seen.whereType<ScenarioTaskFailedEvent>().single;
      expect(fail.kind, isNull);
      expect(fail.reason, contains('cut off'));
      expect(seen.whereType<GameOverEvent>(), isEmpty);
    });
  });
}
