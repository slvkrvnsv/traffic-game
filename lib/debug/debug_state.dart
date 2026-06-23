import '../cars/npc_car.dart';
import '../tiles/tile_base.dart';

/// Shared mutable debug snapshot written by game systems every frame.
/// Only meaningful in kDebugMode — has zero cost in release builds when
/// callers are gated with `if (kDebugMode)`.
class DebugState {
  DebugState._();

  /// False in test mode so end-users see a clean screen. Toggled by TrafficGame.
  static bool showDebug = true;

  // --- Tile info ---
  static String tileType = '';
  static String scenarioType = '';
  static int activeTileCount = 0;
  static List<String> activeTileNames = [];

  // --- Player ---
  static double playerSpeed = 0;
  static double playerT = 0;
  static double playerX = 0;
  static double playerY = 0;
  static bool playerBraking = false;

  // --- NPCs ---
  static List<NpcDebugRow> npcs = [];

  // --- Collision ---
  static bool playerColliding = false;
  static double nearestNpcGap = double.infinity; // center-to-center, game units
  static int npcCollisionLane = -1; // lane index of colliding NPC, -1 if none

  static void updateFromTile(TileBase tile) {
    tileType = tile.tileType.name;
    scenarioType = tile.scenario.runtimeType.toString()
        .replaceFirst('Scenario', '')
        .replaceFirst('FreeDrive', 'FreeDrive');
  }

  static void updateNpcs(List<NpcCar> allNpcs) {
    npcs = allNpcs.map((n) => NpcDebugRow(
      laneIndex: n.laneIndex,
      stateName: n.brain.stateName,
      speed: n.speed,
      targetSpeed: n.targetSpeed,
      leadGap: n.brain.leadCarDistance,
      hasRightOfWay: n.brain.hasRightOfWay,
      intersectionActive: n.brain.intersectionRuleActive,
      t: n.currentT,
    )).toList();
  }
}

class NpcDebugRow {
  const NpcDebugRow({
    required this.laneIndex,
    required this.stateName,
    required this.speed,
    required this.targetSpeed,
    required this.leadGap,
    required this.hasRightOfWay,
    required this.intersectionActive,
    required this.t,
  });

  final int laneIndex;
  final String stateName;
  final double speed;
  final double targetSpeed;
  final double? leadGap;
  final bool hasRightOfWay;
  final bool intersectionActive;
  final double t;

  @override
  String toString() {
    final gap = leadGap == null ? ' ∞' : leadGap!.toStringAsFixed(0).padLeft(3);
    final row = stateName.padRight(14);
    final spd = '${speed.toStringAsFixed(0).padLeft(3)}/${targetSpeed.toStringAsFixed(0).padLeft(3)}';
    final t_ = t.toStringAsFixed(2);
    final flags = [
      if (intersectionActive) hasRightOfWay ? 'ROW' : 'YIELD',
    ].join(' ');
    return 'L$laneIndex $row $spd  gap=$gap  t=$t_  $flags';
  }
}
