import 'package:flutter/material.dart';
import '../core/maneuver.dart';
import '../tiles/tile_registry.dart';

/// One launchable test-mode entry: a tile type, optionally with a pinned
/// maneuver (intersections get one entry per maneuver plus random).
class _TestEntry {
  const _TestEntry(this.label, this.icon, this.type, [this.maneuver]);

  final String label;
  final IconData icon;
  final TileType type;
  final Maneuver? maneuver;
}

/// Test mode: select a tile type (and maneuver) to loop endlessly.
class TestMenuScreen extends StatelessWidget {
  const TestMenuScreen({super.key});

  static List<_TestEntry> _entriesFor(TileType type) => switch (type) {
        TileType.straight => const [
            _TestEntry('Straight Road', Icons.straight_rounded,
                TileType.straight),
          ],
        TileType.intersection4way => const [
            _TestEntry('4-Way Yield — Random', Icons.shuffle_rounded,
                TileType.intersection4way),
            _TestEntry('4-Way Yield — Straight', Icons.straight_rounded,
                TileType.intersection4way, Maneuver.straight),
            _TestEntry('4-Way Yield — Turn Left', Icons.turn_left_rounded,
                TileType.intersection4way, Maneuver.left),
            _TestEntry('4-Way Yield — Turn Right', Icons.turn_right_rounded,
                TileType.intersection4way, Maneuver.right),
          ],
        // The start tile is never registered, so it never reaches here; the
        // wildcard keeps this switch exhaustive over TileType.
        _ => const <_TestEntry>[],
      };

  @override
  Widget build(BuildContext context) {
    final entries = [
      for (final type in TileRegistry.allTypes) ..._entriesFor(type),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        foregroundColor: Colors.white,
        title: const Text(
          'SELECT TILE',
          style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                'No tiles registered yet.',
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 16),
              itemBuilder: (context, i) {
                final entry = entries[i];
                return _TileCard(
                  label: entry.label,
                  icon: entry.icon,
                  onTap: () => Navigator.pushNamed(
                    context,
                    '/game',
                    arguments: {
                      'testMode': entry.type,
                      'testManeuver': entry.maneuver,
                    },
                  ),
                );
              },
            ),
    );
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF30363D), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF42A5F5), size: 32),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
