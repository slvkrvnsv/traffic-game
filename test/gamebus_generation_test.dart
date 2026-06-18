import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/core/game_bus.dart';
import 'package:traffic_game/rules/exam_error.dart';
import 'package:traffic_game/rules/exam_error_log.dart';
import 'package:traffic_game/rules/exam_error_recorder.dart';
import 'package:traffic_game/tiles/tile_manager.dart';

/// The GameBus is a global singleton that outlives a game restart, so a
/// previous game's recorder can leak its subscription. The generation guard
/// must make such a stale recorder inert — otherwise one fault is recorded once
/// per leaked recorder ("missed one stop sign, got 12 faults").
void main() {
  // Mount a recorder and register its teardown, so its bus subscription is
  // cancelled at the end of the test instead of leaking onto the singleton bus.
  ExamErrorRecorder mountRecorder() {
    final r = ExamErrorRecorder(
      tileManager: TileManager(playerCar: PlayerCar(), world: World()),
      log: ExamErrorLog.instance,
    )..onMount();
    addTearDown(r.onRemove);
    return r;
  }

  test('a recorder from a stale generation records nothing', () async {
    GameBus.instance.newGeneration();
    mountRecorder(); // snapshots the current generation
    GameBus.instance.newGeneration(); // a newer game started → it's now stale

    GameBus.instance.emit(ScenarioTaskFailedEvent(
        reason: 'rolled the stop', kind: ExamErrorType.stopSignViolation));
    await pumpEventQueue();

    expect(ExamErrorLog.instance.currentRunErrors, isEmpty,
        reason: 'a leaked recorder from a previous game must not record');
  });

  test('a current-generation recorder records the fault exactly once', () async {
    GameBus.instance.newGeneration();
    mountRecorder(); // current generation; startRun() opens a fresh run

    GameBus.instance.emit(ScenarioTaskFailedEvent(
        reason: 'rolled the stop', kind: ExamErrorType.stopSignViolation));
    await pumpEventQueue();

    final stops = ExamErrorLog.instance.currentRunErrors
        .where((e) => e.type == ExamErrorType.stopSignViolation);
    expect(stops, hasLength(1),
        reason: 'the live recorder logs it once; any stale ones stay inert');
  });
}
