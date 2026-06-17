import 'dart:math' as math;
import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/maneuver.dart';
import '../core/spline.dart';
import '../cars/npc_car.dart';
import '../cars/player_car.dart';
import 'scenarios/scenario_base.dart';
import 'tile_registry.dart';

/// Abstract base for all road tiles.
///
/// Tiles are authored in a *canonical frame*: the player enters at the south
/// edge ([entryAnchor]) heading north (-y) and leaves via [exitAnchor] heading
/// [exitDirection]. Placement in the world is a translation ([position]) plus
/// a rotation ([orientation], multiples of π/2) about the tile origin, so the
/// corridor can bend without any tile knowing its world heading.
abstract class TileBase extends PositionComponent {
  TileBase({
    required this.tileType,
    required this.scenario,
    super.position,
  }) : super(size: Vector2.all(kTileSize));

  final TileType tileType;
  final ScenarioBase scenario;

  List<Spline> get playerPaths;
  List<Spline> get npcPaths;

  /// Whether the player may change lanes while on this tile. Defaults to "only
  /// if there's more than one parallel lane to switch to", so single-lane tiles
  /// (intersection maneuvers, start) turn lane switching off entirely — the
  /// player drives the road, not the turn. Tiles can override.
  bool get allowsLaneChange => playerPaths.length > 1;

  /// Whether the player may change lanes at tile-local [localPos]. Defaults to
  /// the tile-wide [allowsLaneChange]; tiles whose lanes merge or diverge
  /// override this to gate steering by *position* — on only where the two lanes
  /// are (or are about to be) distinct, off where they're coincident so the car
  /// self-centres onto the single lane. Updated every frame by TileManager.
  bool allowsLaneChangeAt(Vector2 localPos) => allowsLaneChange;

  /// SPLINE-STEERING — the reusable "fork" hook.
  ///
  /// A *fork* is anywhere two player lanes are still **near-coincident** while
  /// splitting apart or coming together: the START of a widen (lanes about to
  /// diverge) or the END of a merge (lanes just converged). Both are less than a
  /// real lane-width apart.
  ///
  /// The ordinary lane change leans the car across a lateral *offset* toward the
  /// target lane. That model breaks at a fork because the target lane is
  /// **moving** (opening/closing): the offset cap collapses as the gap appears →
  /// the car snaps, and re-clamping resets the nose every frame → it wobbles.
  ///
  /// Spline-steering sidesteps all of it: in a fork the car simply *follows its
  /// spline*, and a drag SWITCHES which spline it follows. Because the lanes are
  /// near-coincident the switch is position-continuous (no snap), and the
  /// spline's own geometry carries the car into the lane — there's no offset to
  /// jump or cap to reset. Past the fork (lanes a clear lane-width apart) the
  /// ordinary offset lane change takes over ("loosens after the fork").
  ///
  /// To apply it to a tile: override this to return, while the lanes are still
  /// near-coincident (e.g. their separation < [kMinLaneCommitSeparation]), the
  /// player spline a drag in [direction] (+1 right / -1 left) should follow.
  /// Return null where the lanes are clearly separate (→ offset lane change) or
  /// where there's nothing to switch to. `PlayerCar` does the rest: TileManager
  /// pushes the targets each frame, and a drag toward one switches onto it
  /// seamlessly (one switch per drag). Default: never a fork.
  Spline? splineSteerTargetAt(Vector2 localPos, int direction) => null;

  /// Spawnable NPC lanes: each entry is the list of movement paths sharing
  /// one entry point — the spawner picks one per car. The lane index is the
  /// stable identity used for refill counting and (on intersections) the
  /// approach heading. Default: every path is its own single-movement lane.
  List<List<Spline>> get npcLanes => [for (final p in npcPaths) [p]];

  /// True when a path bends significantly between entry and exit (a turn).
  /// Drives NPC `isTurning` so indicators and turn slow-down engage.
  static bool pathTurns(Spline path) =>
      path.tangent(0.0).dot(path.tangent(1.0)) < 0.9;

  Vector2 get entryAnchor;
  Vector2 get exitAnchor;

  /// Unit direction of travel at the exit, in the canonical frame.
  /// North (straight through) unless a maneuver bends the corridor.
  Vector2 get exitDirection => Vector2(0, -1);

  /// The exam instruction this tile gives the player, or null when the tile
  /// has nothing to announce (plain road). Shown by the maneuver HUD.
  Maneuver? get commandedManeuver => null;

  /// HUD instruction text for tiles whose task isn't an intersection maneuver
  /// (e.g. "Merge left"). Null → the HUD uses [commandedManeuver]'s label.
  String? get taskLabel => null;

  double get handOffTriggerT => kHandOffTriggerT;

  final List<NpcCar> npcs = [];

  bool _active = false;
  bool get isActive => _active;

  // ---------------------------------------------------------------------------
  // Placement (world transform)
  // ---------------------------------------------------------------------------

  double _orientation = 0.0;
  double _cosO = 1.0;
  double _sinO = 0.0;

  /// World rotation in radians (multiples of π/2), applied about the tile
  /// origin (top-left corner of the canonical frame).
  double get orientation => _orientation;

  /// Place the tile in the world. Must be called before adding to the world;
  /// tiles never move afterwards.
  void place({required Vector2 worldPosition, required double orientation}) {
    position = worldPosition;
    _orientation = orientation;
    _cosO = math.cos(orientation);
    _sinO = math.sin(orientation);
    angle = orientation; // Flame rotates rendering about the top-left anchor
  }

  Vector2 localToWorld(Vector2 local) => Vector2(
        position.x + local.x * _cosO - local.y * _sinO,
        position.y + local.x * _sinO + local.y * _cosO,
      );

  Vector2 worldToLocal(Vector2 world) {
    final dx = world.x - position.x;
    final dy = world.y - position.y;
    return Vector2(dx * _cosO + dy * _sinO, -dx * _sinO + dy * _cosO);
  }

  /// Rotate a canonical-frame direction vector into the world frame.
  Vector2 directionToWorld(Vector2 local) => Vector2(
        local.x * _cosO - local.y * _sinO,
        local.x * _sinO + local.y * _cosO,
      );

  Vector2 get worldEntry => localToWorld(entryAnchor);
  Vector2 get worldExit => localToWorld(exitAnchor);
  Vector2 get worldExitDirection => directionToWorld(exitDirection);
  Vector2 get worldCenter => localToWorld(Vector2.all(kTileSize / 2));

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  void onActivate() => _active = true;
  void onDeactivate() => _active = false;

  /// True when this tile currently requires the player to be stopped/slow for a
  /// legitimate reason (yielding to cross-traffic, red light, stop sign).
  /// Used by the road-blocking check to exempt rational standstills.
  /// Default: a plain road never requires the player to wait.
  bool get playerMustWait => false;

  /// Posted speed limit for this tile in km/h, or null for no limit. Authored
  /// in km/h (designer-facing); enforcement compares against the player's speed
  /// via [speedLimitUnits]. Hook for the upcoming per-tile speed-limit feature —
  /// override per tile/scenario; not yet enforced.
  double? get speedLimitKmh => null;

  /// [speedLimitKmh] converted to world units/sec, or null when unlimited.
  double? get speedLimitUnits =>
      speedLimitKmh == null ? null : kmhToUnits(speedLimitKmh!);

  // ---------------------------------------------------------------------------
  // Update
  // ---------------------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);
    scenario.update(dt);
  }

  // ---------------------------------------------------------------------------
  // Debug spline rendering — drawn in tile-local coordinates on top of the road.
  // Subclass render() should call super.render(canvas) OR call debugRenderSplines().
  // ---------------------------------------------------------------------------

  /// Call this at the END of any tile's render() when kDebugMode is true.
  /// Draws player paths (green) and NPC paths (orange) as thin sampled lines,
  /// plus entry/exit anchor dots and the conflict zone box if applicable.
  void debugRenderSplines(Canvas canvas) {
    if (!kDebugMode) return;

    // Player paths — bright green
    final playerPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (final s in playerPaths) {
      _drawSplinePath(canvas, s, playerPaint);
    }

    // NPC paths — orange
    final npcPaint = Paint()
      ..color = const Color(0xFFFF6D00)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (final s in npcPaths) {
      _drawSplinePath(canvas, s, npcPaint);
    }

    // Entry anchor — cyan circle
    _drawDot(canvas, entryAnchor, const Color(0xFF00E5FF), 10);

    // Exit anchor — magenta circle
    _drawDot(canvas, exitAnchor, const Color(0xFFE040FB), 10);
  }

  static void _drawSplinePath(Canvas canvas, Spline spline, Paint paint) {
    const samples = 48;
    final path = Path();
    for (int i = 0; i <= samples; i++) {
      final t = i / samples;
      final p = spline.evaluate(t);
      if (i == 0) {
        path.moveTo(p.x, p.y);
      } else {
        path.lineTo(p.x, p.y);
      }
    }
    canvas.drawPath(path, paint);

    // Direction arrow at midpoint
    final mid = spline.evaluate(0.5);
    final tgt = spline.tangent(0.5);
    _drawArrow(canvas, mid, tgt, paint);
  }

  static void _drawArrow(Canvas canvas, Vector2 at, Vector2 dir, Paint paint) {
    const len = 18.0;
    const spread = 0.4;
    final tip = at + dir * len;
    final left = at + (dir * (len * 0.5))
      ..add(Vector2(-dir.y, dir.x) * (len * spread));
    final right = at + (dir * (len * 0.5))
      ..sub(Vector2(-dir.y, dir.x) * (len * spread));
    final path = Path()
      ..moveTo(tip.x, tip.y)
      ..lineTo(left.x, left.y)
      ..lineTo(right.x, right.y)
      ..close();
    // Use a separate fill paint — mutating the caller's stroke paint here
    // would leak fill style into every spline drawn after this arrow,
    // filling curved paths as solid polygons.
    final fill = Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fill);
  }

  static void _drawDot(Canvas canvas, Vector2 at, Color color, double r) {
    canvas.drawCircle(
      Offset(at.x, at.y),
      r,
      Paint()..color = color,
    );
  }

  // ---------------------------------------------------------------------------
  // NPC sensor wiring — called by TileManager every frame.
  // ---------------------------------------------------------------------------

  /// Update all sensor inputs for NPCs belonging to this tile.
  /// Override in subclasses to add intersection-specific logic on top.
  void updateNpcSensors(
    double dt,
    PlayerCar playerCar,
    List<NpcCar> allNpcs,
  ) {
    for (final npc in npcs) {
      npc.brain.leadCarDistance = _leadCarGap(npc, playerCar, allNpcs);
      npc.brain.distanceToTurnSignal = _distanceToTurn(npc);
      // Cleared every frame; tiles that impose a stop (intersections) set it
      // again below. Prevents a stale stop-line target after a tile hand-off.
      npc.brain.stopTargetDistance = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Sensor helpers
  // ---------------------------------------------------------------------------

  /// Euclidean gap to the nearest car directly ahead (same approximate lane).
  /// Returns null if no car is found within a reasonable forward cone.
  double? _leadCarGap(
    NpcCar npc,
    PlayerCar playerCar,
    List<NpcCar> allNpcs,
  ) {
    if (npc.spline == null) return null;

    final cosA = math.cos(npc.angle);
    final sinA = math.sin(npc.angle);
    final forward = Vector2(cosA, sinA);

    double minGap = double.infinity;

    // Check all other live NPCs
    for (final other in allNpcs) {
      if (other == npc) continue;
      final gap = _gapAhead(npc.position, forward, other.position);
      if (gap != null && gap < minGap) minGap = gap;
    }

    // Also treat the player as a possible obstacle (NPC behind player)
    final pgap = _gapAhead(npc.position, forward, playerCar.position);
    if (pgap != null && pgap < minGap) minGap = pgap;

    return minGap.isFinite ? minGap : null;
  }

  /// Returns bumper-to-bumper gap if [other] is ahead and in the same lane,
  /// null otherwise.
  double? _gapAhead(Vector2 from, Vector2 forward, Vector2 other) {
    final delta = other - from;
    final fwd = delta.dot(forward);
    if (fwd < kCarLength * 0.5) return null; // behind or overlapping
    final lateral = (delta - forward * fwd).length;
    if (lateral > kCarWidth * 1.8) return null; // different lane
    return (fwd - kCarLength).clamp(0.0, double.infinity);
  }

  /// Remaining spline distance until the NPC enters a significant curve.
  /// Returns [double.infinity] for straight paths.
  double _distanceToTurn(NpcCar npc) {
    final s = npc.spline;
    if (s == null || !npc.brain.isTurning) return double.infinity;

    final currentT = npc.currentT;
    const steps = 20;
    final baseAngle = s.angleAt(currentT);

    for (int i = 1; i <= steps; i++) {
      final t = currentT + i / steps * (1.0 - currentT);
      final angleDiff = (s.angleAt(t) - baseAngle).abs();
      if (angleDiff > 0.3) {
        // Found the curve — how far is it?
        final curveT = t;
        final distToCurve =
            (curveT - currentT) * s.totalLength;
        return (distToCurve - kIndicatorSignalDistance)
            .clamp(0.0, double.infinity);
      }
    }
    return double.infinity;
  }
}
