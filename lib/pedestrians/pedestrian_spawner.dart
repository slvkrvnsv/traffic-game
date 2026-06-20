import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/spline.dart';
import '../core/utils.dart';
import 'pedestrian.dart';

/// Timed pedestrian spawner for one tile.
///
/// Owned by [TileManager], which calls [update] each frame and adds the returned
/// [Pedestrian]s to the world. The same class drives two flavours, told apart
/// only by which splines and registry it's given:
///   * **ambient** walkers — strolling sidewalk splines, added to a visual-only
///     registry the rules never scan (so they can't be hit or block the road);
///   * **crossing** pedestrians — road-crossing splines, added to the rules
///     registry (cars and the player must yield; a hit is a crash).
class PedestrianSpawner {
  PedestrianSpawner({
    required this.paths,
    required this.spawnIntervalSeconds,
    required this.registry,
    required this.maxActive,
    required this.minSpawnDist,
    Vector2? worldOffset,
    this.worldAngle = 0.0,
    Random? rng,
  })  : worldOffset = worldOffset ?? Vector2.zero(),
        _rng = rng ?? Random();

  /// Splines the spawned pedestrians follow (sidewalk or crossing), tile-local.
  final List<Spline> paths;
  final double spawnIntervalSeconds;

  /// World registry these pedestrians are added to (and removed from when they
  /// finish or the tile is culled). Ambient → GameWorld.ambientPedestrians;
  /// crossing → GameWorld.pedestrians (the one the rules system scans).
  final List<Pedestrian> registry;

  /// Cap on simultaneously-alive pedestrians from this spawner.
  final int maxActive;

  /// Don't spawn a pedestrian whose entry point is closer than this to the
  /// player — the same off-screen discipline NPC cars use, so none pop in on
  /// the bumper.
  final double minSpawnDist;

  /// Owning tile placement, applied to each spawned pedestrian's spline.
  final Vector2 worldOffset;
  final double worldAngle;

  final Random _rng;

  double _timer = 0.0;
  final List<Pedestrian> _active = [];

  // Shirt colours.
  static const _colors = [
    Color(0xFF1565C0),
    Color(0xFF6A1B9A),
    Color(0xFF00695C),
    Color(0xFFBF360C),
    Color(0xFF37474F),
    Color(0xFFAD1457),
    Color(0xFFEF6C00),
    Color(0xFF455A64),
    Color(0xFFF9A825),
    Color(0xFF2E7D32),
  ];

  // Skin tones.
  static const _skins = [
    Color(0xFFF1C9A5),
    Color(0xFFE0AC69),
    Color(0xFFC68642),
    Color(0xFF8D5524),
    Color(0xFFFFDBAC),
  ];

  // Hair colours; `null` = bald.
  static const _hairs = <Color?>[
    Color(0xFF20140A), // near-black
    Color(0xFF4E342E), // dark brown
    Color(0xFF7A4B25), // brown
    Color(0xFFC9A227), // blonde
    Color(0xFF9E9E9E), // grey
    Color(0xFFB71C1C), // ginger
    null, // bald
  ];

  bool get anyInPath => _active.any((p) => !p.hasCrossed);

  /// Returns any newly spawned [Pedestrian] (caller adds to world).
  /// [playerPosition] gates spawning so no pedestrian materialises near the
  /// player (the off-screen discipline NPC cars use).
  List<Pedestrian> update(double dt, Vector2 playerPosition) {
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
    if (paths.isEmpty || _active.length >= maxActive) {
      _timer = 0.0;
      return const [];
    }

    final spline = paths[_rng.nextInt(paths.length)];
    // Spawn guard: if this entry point is too close to the player, hold (leave
    // the timer armed) and retry next frame — so the pedestrian appears once the
    // point is far enough away, never popping in on-screen on top of the player.
    if (_worldStart(spline).distanceTo(playerPosition) < minSpawnDist) {
      return const [];
    }
    _timer = 0.0;

    final ped = Pedestrian(
      crossingPath: spline,
      walkSpeed: randomRange(_rng, kPedMinWalkSpeed, kPedMaxWalkSpeed),
      color: _colors[_rng.nextInt(_colors.length)],
      skinColor: _skins[_rng.nextInt(_skins.length)],
      hairColor: _hairs[_rng.nextInt(_hairs.length)],
      worldOffset: worldOffset,
      worldAngle: worldAngle,
    );
    _active.add(ped);
    registry.add(ped);
    return [ped];
  }

  /// World-space entry point (t=0) of [s] under the owning tile's placement —
  /// the same transform [Pedestrian] applies, used for the spawn-distance guard.
  Vector2 _worldStart(Spline s) {
    final p = s.evaluate(0.0);
    final c = cos(worldAngle), sn = sin(worldAngle);
    return Vector2(
      worldOffset.x + p.x * c - p.y * sn,
      worldOffset.y + p.x * sn + p.y * c,
    );
  }

  /// Remove every live pedestrian from this spawner — called when the owning
  /// tile is culled so its walkers don't outlive it.
  void dispose() {
    for (final p in _active) {
      p.removeFromParent();
      registry.remove(p);
    }
    _active.clear();
  }
}
