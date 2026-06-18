import 'package:flutter/material.dart';
import '../rules/exam_error.dart';
import '../rules/exam_error_log.dart';

/// A small warning chip under the speedometer showing how many faults the
/// player has racked up this run. Tap it to read the full fault log. Faults are
/// non-fatal (only a crash ends the run), so this is the one place the player
/// sees that they *did* slip up — and what on.
class FaultLogHud extends StatelessWidget {
  const FaultLogHud({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        // Tucked just below the 88px speedometer (top:12) on the right edge.
        child: Padding(
          padding: const EdgeInsets.only(top: 112, right: 36),
          child: ValueListenableBuilder<int>(
            valueListenable: ExamErrorLog.instance.currentRunCount,
            builder: (context, count, _) => _FaultChip(
              count: count,
              onTap: () => _showLog(context),
            ),
          ),
        ),
      ),
    );
  }

  void _showLog(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _FaultLogSheet(),
    );
  }
}

class _FaultChip extends StatelessWidget {
  const _FaultChip({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final clean = count == 0;
    final accent = clean ? const Color(0xFF4CAF50) : const Color(0xFFFFB300);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xE6111111),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withValues(alpha: 0.7), width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              clean ? Icons.check_circle_outline : Icons.warning_amber_rounded,
              color: accent,
              size: 22,
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: TextStyle(
                color: accent,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FaultLogSheet extends StatelessWidget {
  const _FaultLogSheet();

  @override
  Widget build(BuildContext context) {
    // Newest first — the most recent mistake is the one the player wants.
    final errors = ExamErrorLog.instance.currentRunErrors.reversed.toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Color(0xFFFFB300), size: 22),
                const SizedBox(width: 8),
                Text(
                  'FAULTS THIS RUN  (${errors.length})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (errors.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Clean run so far — no faults logged.',
                  style: TextStyle(color: Colors.white54),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: errors.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: Color(0xFF30363D), height: 16),
                  itemBuilder: (_, i) => _FaultRow(errors[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FaultRow extends StatelessWidget {
  const _FaultRow(this.error);

  final ExamError error;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _badge(error.type.category);
    final subtitle = [
      if (error.detail != null) error.detail!,
      'on ${error.tileType}',
      if (error.speed != null) '@ ${error.speed!.toStringAsFixed(0)}',
    ].join(' · ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                error.type.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Icon + colour for each fault stream — the same split the fail model uses.
  (IconData, Color) _badge(ExamErrorCategory category) => switch (category) {
        ExamErrorCategory.fault => (
            Icons.rule_rounded,
            const Color(0xFFFFB300)
          ),
        ExamErrorCategory.unsafe => (
            Icons.priority_high_rounded,
            const Color(0xFFFF7043)
          ),
        ExamErrorCategory.crash => (
            Icons.car_crash_rounded,
            const Color(0xFFEF5350)
          ),
      };
}
