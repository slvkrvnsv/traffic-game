import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/rules/exam_error.dart';
import 'package:traffic_game/rules/exam_error_log.dart';

void main() {
  test('ExamError JSON round-trip preserves all fields', () {
    final error = ExamError(
      type: ExamErrorType.failedToYield,
      runId: 'run-1',
      at: DateTime.parse('2026-06-11T12:00:00'),
      tileType: 'intersection4way',
      maneuver: Maneuver.left,
      speed: 123.4,
      detail: 'test',
    );

    final back = ExamError.fromJson(error.toJson());
    expect(back.type, ExamErrorType.failedToYield);
    expect(back.runId, 'run-1');
    expect(back.at, DateTime.parse('2026-06-11T12:00:00'));
    expect(back.tileType, 'intersection4way');
    expect(back.maneuver, Maneuver.left);
    expect(back.speed, 123.4);
    expect(back.detail, 'test');
  });

  test('log records, groups by run, persists and reloads', () async {
    final dir = await Directory.systemTemp.createTemp('exam_errors_test');
    addTearDown(() => dir.delete(recursive: true));

    final log = ExamErrorLog.instance;
    log.storageFileOverride = File('${dir.path}/errors.json');

    log.startRun();
    final firstRun = log.currentRunId;
    log.record(ExamError(
      type: ExamErrorType.collision,
      runId: firstRun,
      at: DateTime.now(),
      tileType: 'straight',
      detail: 'npc_car',
    ));

    log.startRun(); // new run — previous error no longer "current"
    log.record(ExamError(
      type: ExamErrorType.failedToYield,
      runId: log.currentRunId,
      at: DateTime.now(),
      tileType: 'intersection4way',
      maneuver: Maneuver.right,
      speed: 80,
    ));

    expect(log.currentRunErrors.length, 1);
    expect(log.currentRunErrors.single.type, ExamErrorType.failedToYield);
    expect(log.all.length, greaterThanOrEqualTo(2));

    await log.flush();
    final countBeforeReload = log.all.length;
    await log.load();
    expect(log.all.length, countBeforeReload);
    expect(log.all.last.maneuver, Maneuver.right);
  });
}
