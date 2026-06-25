import '../core/maneuver.dart';

/// Every kind of rule-break the exam can record. One entry per violation
/// event type on the GameBus.
enum ExamErrorType {
  failedToYield,
  stopSignViolation,
  redLightViolation,
  roadBlocking,
  blockedIntersection,
  wrongLane,

  /// Changed lanes (or merged) without the turn signal armed that way. Detected
  /// globally at the lane-change commit — not tied to any one tile.
  laneChangeWithoutSignal,

  /// Took a commanded turn without the turn signal armed that way. Detected
  /// globally at the turn commit — not tied to any one tile.
  turnWithoutSignal,

  /// A scenario task failed but isn't one of the specific rules above — e.g. an
  /// unsafe merge. The human-readable reason rides in [ExamError.detail].
  scenarioFault,

  /// An NPC threw the "!" warning because the player forced them to brake hard
  /// (a cut-off). Unsafe-driving, not a failed task.
  cutOff,

  collision,
}

/// Which fault log an [ExamErrorType] belongs to.
///
/// The fail model splits non-crash mistakes into two streams the user reviews
/// separately: failed exam *tasks* (feeds the "how you should've done it"
/// explainer) and *unsafe* driving (the NPC "!" reactions). A crash is its own
/// terminal thing — the only game-over.
enum ExamErrorCategory { fault, unsafe, crash }

extension ExamErrorTypeLabel on ExamErrorType {
  String get label => switch (this) {
        ExamErrorType.failedToYield => 'Failed to yield',
        ExamErrorType.stopSignViolation => 'Missed a stop sign',
        ExamErrorType.redLightViolation => 'Ran a red light',
        ExamErrorType.roadBlocking => 'Blocked the road',
        ExamErrorType.blockedIntersection => 'Blocked the intersection',
        ExamErrorType.wrongLane => 'Wrong lane for the turn',
        ExamErrorType.laneChangeWithoutSignal => 'Changed lanes without signalling',
        ExamErrorType.turnWithoutSignal => 'Turned without signalling',
        ExamErrorType.scenarioFault => 'Failed the maneuver',
        ExamErrorType.cutOff => 'Cut off a driver',
        ExamErrorType.collision => 'Collision',
      };

  ExamErrorCategory get category => switch (this) {
        ExamErrorType.failedToYield ||
        ExamErrorType.stopSignViolation ||
        ExamErrorType.redLightViolation ||
        ExamErrorType.roadBlocking ||
        ExamErrorType.blockedIntersection ||
        ExamErrorType.wrongLane ||
        ExamErrorType.laneChangeWithoutSignal ||
        ExamErrorType.turnWithoutSignal ||
        ExamErrorType.scenarioFault =>
          ExamErrorCategory.fault,
        ExamErrorType.cutOff => ExamErrorCategory.unsafe,
        ExamErrorType.collision => ExamErrorCategory.crash,
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
