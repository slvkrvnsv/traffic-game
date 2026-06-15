import 'dart:math';
import 'scenario_base.dart';
import 'free_drive_scenario.dart';
import 'yield_scenario.dart';
import '../tile_registry.dart';

/// Maps each [TileType] to the rule variants its geometry can be dressed
/// with. This is the geometry × scenario seam: a stop-sign or traffic-light
/// variant of the 4-way intersection is one new scenario class + one entry
/// here — no new tile geometry.
class ScenarioRegistry {
  ScenarioRegistry._();

  static final Map<TileType, List<ScenarioBase Function()>> _map = {
    TileType.straight: [
      () => FreeDriveScenario(),
    ],
    TileType.intersection4way: [
      () => YieldScenario(),
      // Future: () => StopSignScenario(), () => TrafficLightScenario(),
    ],
  };

  /// Return a random eligible scenario for the given tile type.
  static ScenarioBase forTile(TileType type, {Random? rng}) {
    final factories = _map[type];
    if (factories == null || factories.isEmpty) return FreeDriveScenario();
    final r = rng ?? Random();
    return factories[r.nextInt(factories.length)]();
  }
}
