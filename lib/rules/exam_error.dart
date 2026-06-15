import '../core/maneuver.dart';

/// Every kind of rule-break the exam can record. One entry per violation
/// event type on the GameBus.
enum ExamErrorType {
  failedToYield,
  stopSignViolation,
  redLightViolation,
  roadBlocking,
  collision,
}

extension ExamErrorTypeLabel on ExamErrorType {
  String get label => switch (this) {
        ExamErrorType.failedToYield => 'Failed to yield',
        ExamErrorType.stopSignViolation => 'Missed a stop sign',
        ExamErrorType.redLightViolation => 'Ran a red light',
        ExamErrorType.roadBlocking => 'Blocked the road',
        ExamErrorType.collision => 'Collision',
      };
}

/// One recorded rule-break — a line on the exam fault sheet. Not scored or
/// counted toward lives yet; tracked and persisted so future scoring,
/// statistics, or an exam-results screen can build on real data.
class ExamError {
  const ExamError({
    required this.type,
    required this.runId,
    required this.at,
    required this.tileType,
    this.maneuver,
    this.speed,
    this.detail,
  });

  final ExamErrorType type;

  /// Groups errors belonging to one play session (set at world boot).
  final String runId;

  final DateTime at;

  /// TileType.name of the tile the player was on.
  final String tileType;

  /// The commanded maneuver at the time, if the tile had one.
  final Maneuver? maneuver;

  /// Player speed when the error fired (e.g. speed crossing a yield line).
  final double? speed;

  /// Free-form extra context (e.g. what was hit in a collision).
  final String? detail;

  Map<String, Object?> toJson() => {
        'type': type.name,
        'runId': runId,
        'at': at.toIso8601String(),
        'tileType': tileType,
        if (maneuver != null) 'maneuver': maneuver!.name,
        if (speed != null) 'speed': speed,
        if (detail != null) 'detail': detail,
      };

  static ExamError fromJson(Map<String, Object?> json) => ExamError(
        type: ExamErrorType.values.byName(json['type'] as String),
        runId: json['runId'] as String? ?? '',
        at: DateTime.parse(json['at'] as String),
        tileType: json['tileType'] as String? ?? '',
        maneuver: json['maneuver'] == null
            ? null
            : Maneuver.values.byName(json['maneuver'] as String),
        speed: (json['speed'] as num?)?.toDouble(),
        detail: json['detail'] as String?,
      );
}
