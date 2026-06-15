import 'package:flutter/material.dart';
import '../core/maneuver.dart';
import '../rules/exam_error.dart';
import '../rules/exam_error_log.dart';

/// Overlay shown when the game ends. Displays the violation reason, the
/// exam fault sheet for this run, and a retry button.
class GameOverOverlay extends StatelessWidget {
  const GameOverOverlay({
    super.key,
    required this.reason,
    required this.onRetry,
  });

  final String reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEF5350), width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFEF5350), size: 56),
              const SizedBox(height: 16),
              const Text(
                'GAME OVER',
                style: TextStyle(
                  color: Color(0xFFEF5350),
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                reason,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              _FaultSheet(errors: ExamErrorLog.instance.currentRunErrors),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF66BB6A),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 40, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'TRY AGAIN',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The exam fault sheet for this run: every recorded error, one line each.
class _FaultSheet extends StatelessWidget {
  const _FaultSheet({required this.errors});

  final List<ExamError> errors;

  @override
  Widget build(BuildContext context) {
    if (errors.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF12121F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ERRORS THIS RUN — ${errors.length}',
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          for (final e in errors.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.close_rounded,
                      color: Color(0xFFEF5350), size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      e.maneuver == null
                          ? e.type.label
                          : '${e.type.label} — ${e.maneuver!.label.toLowerCase()}',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (errors.length > 5)
            Text(
              '+${errors.length - 5} more',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
