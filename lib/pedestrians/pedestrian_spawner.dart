import 'dart:math';
import 'package:flutter/material.dart';
import '../core/spline.dart';
import '../core/utils.dart';
import 'pedestrian.dart';

/// Timed pedestrian spawner for a tile.
/// Call [update] every frame; add returned [Pedestrian] components to the world.
class PedestrianSpawner {
  PedestrianSpawner({
    required this.crossingSplines,
    required this.spawnIntervalSeconds,
    required this.registry,
    Random? rng,
  }) : _rng = rng ?? Random();

  final List<Spline> crossingSplines;
  final double spawnIntervalSeconds;

  /// World-owned list of all live pedestrians (GameWorld.pedestrians) —
  /// mirrors NpcSpawner.allNpcs for ViolationDetector.
  final List<Pedestrian> registry;

  final Random _rng;

  double _timer = 0.0;
  final List<Pedestrian> _active = [];

  static const _colors = [
    Color(0xFF1565C0),
    Color(0xFF6A1B9A),
    Color(0xFF00695C),
    Color(0xFFBF360C),
  ];

  bool get anyInPath => _active.any((p) => !p.hasCrossed);

  /// Returns any newly spawned [Pedestrian] (caller adds to world).
  List<Pedestrian> update(double dt) {
    _timer += dt;
    _active.removeWhere((p) {
      if (p.hasCrossed) {
        p.removeFromParent();
        registry.remove(p);
        return true;
      }
      return false;
    });

    if (_timer < spawnIntervalSeconds) return const [];
    _timer = 0.0;

    if (crossingSplines.isEmpty) return const [];
    final spline = crossingSplines[_rng.nextInt(crossingSplines.length)];
    final speed = randomRange(_rng, 40.0, 80.0);
    final color = _colors[_rng.nextInt(_colors.length)];

    final ped = Pedestrian(
      crossingPath: spline,
      walkSpeed: speed,
      color: color,
    );
    _active.add(ped);
    registry.add(ped);
    return [ped];
  }
}
