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

/// Test mode: select a tile type (and maneuver) to loop endlessly, plus the
/// locale (urban / interurban) every tile is dressed as.
class TestMenuScreen extends StatefulWidget {
  const TestMenuScreen({super.key});

  @override
  State<TestMenuScreen> createState() => _TestMenuScreenState();
}

class _TestMenuScreenState extends State<TestMenuScreen> {
  LocaleType _locale = LocaleType.interurban;

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
            _tile('4-Way Stop — Random', Icons.shuffle_rounded,
                TileType.intersection4way),
            _tile('4-Way Stop — Straight', Icons.straight_rounded,
                TileType.intersection4way, Maneuver.straight),
            _tile('4-Way Stop — Turn Left', Icons.turn_left_rounded,
                TileType.intersection4way, Maneuver.left),
            _tile('4-Way Stop — Turn Right', Icons.turn_right_rounded,
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
      _TestEntry('Connectors', Icons.merge_rounded,
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
      body: Column(
        children: [
          _LocaleToggle(
            value: _locale,
            onChanged: (l) => setState(() => _locale = l),
          ),
          Expanded(
            child: entries.isEmpty
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
                          // Ride the chosen locale along with the tile args.
                          arguments: {...entry.arguments, 'testLocale': _locale},
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Two-segment urban / interurban picker shown above the tile list.
class _LocaleToggle extends StatelessWidget {
  const _LocaleToggle({required this.value, required this.onChanged});

  final LocaleType value;
  final ValueChanged<LocaleType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          for (final l in LocaleType.values)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: l == LocaleType.values.first ? 12 : 0),
                child: GestureDetector(
                  onTap: () => onChanged(l),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: value == l
                          ? const Color(0xFF42A5F5)
                          : const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: value == l
                            ? const Color(0xFF42A5F5)
                            : const Color(0xFF30363D),
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      l == LocaleType.urban ? 'URBAN' : 'INTERURBAN',
                      style: TextStyle(
                        color: value == l ? Colors.white : Colors.white60,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
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
            Expanded(
              child: Text(
                label,
                softWrap: true,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
