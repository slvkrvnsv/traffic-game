import 'package:flutter/material.dart';
import '../core/maneuver.dart';
import '../tiles/tile_registry.dart';

/// One launchable test-mode entry: a label + icon and the `/game` route
/// arguments it launches with (a single looped tile, or a sequenced course).
class _TestEntry {
  const _TestEntry(this.label, this.icon, this.arguments);

  final String label;
  final IconData icon;
  final Map<String, dynamic> arguments;
}

/// Test mode: select a tile type (and maneuver) to loop endlessly.
class TestMenuScreen extends StatelessWidget {
  const TestMenuScreen({super.key});

  /// A looped tile-type entry (optionally with a pinned maneuver).
  static _TestEntry _tile(String label, IconData icon, TileType type,
          [Maneuver? maneuver]) =>
      _TestEntry(label, icon,
          {'testMode': type, 'testManeuver': maneuver});

  /// The lane-transition course: 2-lane → merge (2→1) → 1-lane → extend (1→2),
  /// looped. Exercises both connectors and both straights in sequence.
  static const _connectorsCourse = [
    TileType.straight,
    TileType.laneMerge,
    TileType.straight1Lane,
    TileType.laneExtend,
  ];

  static List<_TestEntry> _entriesFor(TileType type) => switch (type) {
        TileType.straight => [
            _tile('Straight Road', Icons.straight_rounded, TileType.straight),
          ],
        TileType.intersection4way => [
            _tile('4-Way Yield — Random', Icons.shuffle_rounded,
                TileType.intersection4way),
            _tile('4-Way Yield — Straight', Icons.straight_rounded,
                TileType.intersection4way, Maneuver.straight),
            _tile('4-Way Yield — Turn Left', Icons.turn_left_rounded,
                TileType.intersection4way, Maneuver.left),
            _tile('4-Way Yield — Turn Right', Icons.turn_right_rounded,
                TileType.intersection4way, Maneuver.right),
          ],
        // straight1Lane / laneMerge / laneExtend are only meaningful chained in
        // the Connectors course (alone they'd seam a 1-lane end onto a 2-lane
        // start). The wildcard keeps this switch exhaustive over TileType.
        _ => const <_TestEntry>[],
      };

  @override
  Widget build(BuildContext context) {
    final entries = [
      _TestEntry('Connectors — Merge & Extend', Icons.merge_rounded,
          {'testSequence': _connectorsCourse}),
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
                    arguments: entry.arguments,
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
