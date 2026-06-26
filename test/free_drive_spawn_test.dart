import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_one_lane_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_transition_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/definitions/start_tile.dart';

/// Proves the 2-lane traffic-light intersection ([TileType.intersectionLight])
/// is wired into the real free-drive game mode — not just *selectable* by
/// [TileManager.pickFreeDriveType] (the chain test covers that), but actually
/// PLACED and handed off through the live [TileManager], in BOTH locales.
///
/// The tile is non-square (1200×1640). The spawn loop re-rolls the tile *type*
/// when its footprint overlaps the live chain ([TileManager] ~L777), so a tall
/// tile that systematically overlapped would be silently swapped for a square
/// one every time → registered-but-never-placed. This test drives the real
/// manager unpinned and asserts the light actually shows up as the active tile
/// the player drives onto (placement + hand-off), settling it empirically.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    StraightTile.register();
    StraightOneLaneTile.register();
    LaneTransitionTile.register();
    IntersectionTile.register();
    IntersectionLightTile.register();
    StartTile.register();
  });
  tearDown(InputState.instance.reset);

  /// Drive a real free-drive chain (unpinned tile type) STRAIGHT at full speed
  /// with the given locale pinned and a seeded RNG, collecting the set of tile
  /// types the player actually drives onto (the active tile each frame). NPCs
  /// and pedestrians are cleared every frame so nothing stalls the run; the
  /// player is gas-pinned so it always reaches each tile's end and hands off.
  Set<TileType> typesDrivenThrough({
    required LocaleType locale,
    required int seed,
    int maxFrames = 60000,
  }) {
    final player = PlayerCar();
    final peds = <Pedestrian>[];
    final ambient = <Pedestrian>[];
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: peds,
      ambientPedestrians: ambient,
      testLocale: locale, // pin the locale; type/maneuver still free-drive
      rng: math.Random(seed),
    );
    tm.bootstrap();
    InputState.instance.setGasLevel(1.0); // straight ahead, no lane steer

    final seen = <TileType>{};
    for (int i = 0; i < maxFrames; i++) {
      player.speed = kPlayerMaxSpeed; // pin so it never grade-stops or decels
      tm.allNpcs.clear(); // no NPCs → no collisions/stalls
      peds.clear();
      ambient.clear();
      player.update(1 / 60);
      tm.update(1 / 60);
      final t = tm.activeTile?.tileType;
      if (t != null) seen.add(t);
      if (seen.contains(TileType.intersectionLight)) break; // proven; stop early
    }
    return seen;
  }

  test('INTERURBAN free-drive places & hands off the 2-lane light intersection',
      () {
    final seen = typesDrivenThrough(
        locale: LocaleType.interurban, seed: 7);
    expect(seen, contains(TileType.intersectionLight),
        reason: 'the non-square 2-lane light must actually place and hand off '
            'in interurban free-drive (not be re-rolled away on overlap)');
  });

  test('URBAN free-drive places & hands off the 2-lane light intersection', () {
    // Urban additionally exercises the light tile's pedestrian-spawner creation
    // (building exit routes / crossings) on a freshly-placed free-drive tile.
    final seen = typesDrivenThrough(locale: LocaleType.urban, seed: 7);
    expect(seen, contains(TileType.intersectionLight),
        reason: 'the non-square 2-lane light must actually place and hand off '
            'in urban free-drive');
  });
}
