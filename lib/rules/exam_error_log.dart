import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'exam_error.dart';

/// App-scoped store of recorded [ExamError]s.
///
/// Lives across game restarts (unlike the per-run world objects) because the
/// history must survive them — that's why it is a singleton like the other
/// app-scoped state (InputState, SpeedState). Persists to a JSON file in the
/// app documents directory; persistence failures never break gameplay.
class ExamErrorLog {
  ExamErrorLog._();
  static final ExamErrorLog instance = ExamErrorLog._();

  /// Test seam: when set, persist here instead of the documents directory.
  @visibleForTesting
  File? storageFileOverride;

  static const _fileName = 'exam_errors.json';

  /// Cap so the file can't grow forever; oldest entries are dropped first.
  static const int _maxStoredErrors = 500;

  final List<ExamError> _all = [];
  String _currentRunId = '';

  /// Live count of faults recorded in the current run — drives the HUD counter.
  /// Bumped on [record], reset on [startRun].
  final ValueNotifier<int> currentRunCount = ValueNotifier<int>(0);

  /// Full persisted history (oldest first).
  List<ExamError> get all => List.unmodifiable(_all);

  /// Errors recorded since the last [startRun].
  List<ExamError> get currentRunErrors =>
      _all.where((e) => e.runId == _currentRunId).toList();

  /// This run's failed scenario tasks — the stream the "how you should've done
  /// it" review reads from (yield/stop/red/road-block/unsafe-merge).
  List<ExamError> get currentRunFaults => currentRunErrors
      .where((e) => e.type.category == ExamErrorCategory.fault)
      .toList();

  /// This run's unsafe-driving events — the NPC "!" reactions (cut-offs).
  List<ExamError> get currentRunUnsafe => currentRunErrors
      .where((e) => e.type.category == ExamErrorCategory.unsafe)
      .toList();

  String get currentRunId => _currentRunId;

  /// Begin a new run (called when a fresh GameWorld boots). Errors recorded
  /// from now on are grouped under this run id.
  void startRun() {
    _currentRunId = DateTime.now().toIso8601String();
    currentRunCount.value = 0;
  }

  void record(ExamError error) {
    _all.add(error);
    if (_all.length > _maxStoredErrors) {
      _all.removeRange(0, _all.length - _maxStoredErrors);
    }
    currentRunCount.value = currentRunErrors.length;
    debugPrint('[EXAM] error: ${error.type.name} on ${error.tileType}'
        '${error.maneuver != null ? ' (${error.maneuver!.name})' : ''}'
        '  run total=${currentRunErrors.length}');
    _save(); // fire-and-forget; gameplay never waits on disk
  }

  /// Await any pending persistence — tests only (gameplay never waits on disk).
  @visibleForTesting
  Future<void> flush() => _save();

  /// Load persisted history. Call once at app startup; failures (first run,
  /// corrupt file, missing plugin in tests) just start with an empty log.
  Future<void> load() async {
    try {
      final file = await _storageFile();
      if (file == null || !await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return;
      _all
        ..clear()
        ..addAll(raw.whereType<Map<String, Object?>>().map(ExamError.fromJson));
    } catch (e) {
      debugPrint('[EXAM] could not load error log: $e');
    }
  }

  Future<void> _save() async {
    try {
      final file = await _storageFile();
      if (file == null) return;
      await file.writeAsString(
        jsonEncode([for (final e in _all) e.toJson()]),
      );
    } catch (e) {
      debugPrint('[EXAM] could not save error log: $e');
    }
  }

  Future<File?> _storageFile() async {
    if (storageFileOverride != null) return storageFileOverride;
    try {
      final dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/$_fileName');
    } catch (_) {
      // No platform channel (unit tests) — run without persistence.
      return null;
    }
  }
}
