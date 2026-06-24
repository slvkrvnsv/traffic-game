import 'dart:math' as math;
import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/maneuver.dart';
import '../debug/debug_state.dart';
import '../core/spline.dart';
import '../cars/npc_car.dart';
import '../cars/player_car.dart';
import '../pedestrians/pedestrian.dart';
import 'environment.dart';
import 'scenarios/scenario_base.dart';
import 'tile_registry.dart';

/// A pedestrian spawn route that starts at a building door. [crossesRoad] tags
/// whether the route steps onto the carriageway (a zebra crossing → goes in the
/// rules pedestrian registry), versus a sidewalk-only stroll (visual only).
class PedSpawnRoute {
  const PedSpawnRoute(this.spline, {required this.crossesRoad});
  final Spline spline;
  final bool crossesRoad;
}

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
    this.locale = LocaleType.interurban,
    super.position,
    Vector2? size,
  }) : super(size: size ?? Vector2.all(kTileSize));

  final TileType tileType;
  final ScenarioBase scenario;

  /// The setting this tile is dressed for (urban vs interurban) — drives
  /// [groundColor], the procedural [decorationZones] dressing, and pedestrian
  /// density. Set once at construction from the spawn context.
  final LocaleType locale;

  List<Spline> get playerPaths;
  List<Spline> get npcPaths;

  /// Extra player-reachable splines to draw in the debug overlay beyond
  /// [playerPaths] — e.g. turn-fork branches that aren't the default lane path.
  List<Spline> get debugExtraSplines => const [];

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

  /// TURN TAPS — the reusable, jump-free "hang a turn on a through-lane" hook.
  ///
  /// Branch splines that TAP onto [spine] within THIS tile: each one's start sits
  /// exactly ON [spine] (a coincident point), then it curves away to a connected
  /// road. Empty (default) → [spine] is a plain lane with no turns; it runs to the
  /// tile edge and hands off normally. When the player CROSSES a branch's tap point
  /// while leaning toward that branch's side, TileManager diverts onto it with a
  /// selection-click and "leaves the tap behind"; crossing it neutral stays straight
  /// on the spine. The coincident start is what makes the switch position-continuous.
  /// Because the spine is ONE continuous spline (never chopped to make a fork), the
  /// parallel-lane merge ([playerLaneMates]) never sees a seam — that is the whole
  /// reason taps replaced end-of-spline forks. Near/far turns are just two taps on
  /// one spine at two depths; nothing about them is special.
  List<Spline> playerBranches(Spline spine) => const [];

  /// The parallel lane-mates of [current] on THIS tile — the set the player may
  /// MERGE among while following [current]. This is what makes lane changing
  /// spline-network-driven rather than fixed per tile: TileManager sets it as the
  /// player's lane options whenever it assigns a spline (hand-off AND fork). Default:
  /// the full [playerPaths] when [current] is one of them (an ordinary multi-lane
  /// road, mates anywhere along it), else just [current] (a lone spline has no mate).
  /// A tile whose lane structure CHANGES along the route overrides this — e.g. the
  /// intersection: the two through-lane spines are mates the whole height (the
  /// straight corridor), and PAST a turn the two exit lanes of that side are mates
  /// (so you can still merge after the turn). Without this, the player gets stranded
  /// one-lane past any branch.
  List<Spline> playerLaneMates(Spline current) =>
      playerPaths.contains(current) ? playerPaths : [current];

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

  /// Set by a tile whose EXIT direction is decided late — the 2-lane light,
  /// where the corridor turns only once the player commits to the turn lane at
  /// the box ("miss = straight"). When true, TileManager re-places the
  /// already-streamed downstream tiles against this tile's now-final exit and
  /// clears it. Tiles whose exit is known at spawn never set it.
  bool exitChanged = false;

  /// Called once when the player is assigned to this tile, BEFORE [playerPaths]
  /// is read, with the player's current lane-centre world position. A tile that
  /// late-binds its commanded maneuver from the entry lane (the 2-lane light
  /// always sets a task requiring a lane change) overrides this. Default: no-op.
  void bindPlayerEntry(Vector2 playerCentreWorld) {}

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

  /// Rotate a world-frame direction vector into the tile's canonical frame
  /// (rotation-only inverse of [directionToWorld] — no translation).
  Vector2 directionToLocal(Vector2 world) => Vector2(
        world.x * _cosO + world.y * _sinO,
        -world.x * _sinO + world.y * _cosO,
      );

  Vector2 get worldEntry => localToWorld(entryAnchor);
  Vector2 get worldExit => localToWorld(exitAnchor);
  Vector2 get worldExitDirection => directionToWorld(exitDirection);
  Vector2 get worldCenter => localToWorld(size / 2);

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

  /// Whether the generic player-cut-off detector (the NPC "!" reaction) should
  /// be suppressed right now. A tile that grades right-of-way itself only gets
  /// false positives from it — most visibly a freshly-spawned car barrelling up
  /// behind the player while it waits its turn. The all-way stop suppresses it
  /// outright; the multi-lane light suppresses it only near/in the box (so a
  /// genuine lane-change cut-off on the open approach still reads). Default: off.
  bool get suppressDriverReactions => false;

  /// Whether a crossing pedestrian at world [worldPos] heading [worldDir] must
  /// hold at the curb for a traffic signal — i.e. the crossing it is about to
  /// step onto is showing don't-walk. Default: no signal here (stop-sign and
  /// plain tiles never hold pedestrians). A traffic-light intersection overrides
  /// it. Set on the pedestrian each frame by TileManager.
  bool pedestrianHeldBySignal(Vector2 worldPos, Vector2 worldDir) => false;

  /// Posted speed limit for this tile in km/h, or null for no limit. Authored
  /// in km/h (designer-facing); enforcement compares against the player's speed
  /// via [speedLimitUnits]. Hook for the upcoming per-tile speed-limit feature —
  /// override per tile/scenario; not yet enforced.
  double? get speedLimitKmh => null;

  /// [speedLimitKmh] converted to world units/sec, or null when unlimited.
  double? get speedLimitUnits =>
      speedLimitKmh == null ? null : kmhToUnits(speedLimitKmh!);

  // ---------------------------------------------------------------------------
  // Environment dressing (locale-driven) — see EnvironmentDecorator
  // ---------------------------------------------------------------------------

  /// Ground fill, by locale: countryside grass vs a paler urban ground.
  Color get groundColor => const Color(0xFF4CAF50); // grass green

  /// Tile-local rectangles of off-road grass scattered with trees (interurban).
  /// Must lie clear of the road, pavement and every spline. Default: none.
  List<Rect> get decorationZones => const [];

  /// Street frontages lined with building blocks (urban) — a row of roofs along
  /// each, facing the sidewalk. Default: none.
  List<Frontage> get buildingFrontages => const [];

  /// Tile-local splines pedestrians stroll along the pavement (visual only,
  /// never entering the carriageway). Default: none.
  List<Spline> get sidewalkPaths => const [];

  /// Tile-local splines pedestrians use to *cross the road* — rule-relevant
  /// (cars and the player must yield, hitting one is a crash). Only urban
  /// intersections author these. Default: none.
  List<Spline> get crossingPaths => const [];

  EnvironmentDecorator? _decor;

  /// Deterministic per-placement seed so scenery is stable as tiles recycle
  /// (never regenerated per frame). [position] is fixed once [place]d.
  int get _decorSeed =>
      (position.x.round() * 73856093) ^ (position.y.round() * 19349663);

  /// The tile's scenery, built once (after [place], so the seed is stable).
  /// Shared by rendering and the building-exit pedestrian routes.
  EnvironmentDecorator get decoration => _decor ??= EnvironmentDecorator(
        locale: locale,
        seed: _decorSeed,
        zones: decorationZones,
        frontages: buildingFrontages,
      );

  /// Draw locale scenery on top of the ground. Call near the end of [render]
  /// (after the road, before debug overlays). No-op when there's nothing to draw.
  void drawDecorations(Canvas canvas) {
    if (decorationZones.isEmpty && buildingFrontages.isEmpty) return;
    decoration.render(canvas);
  }

  /// Routes for pedestrians *leaving the buildings*: from a building door out to
  /// the nearest sidewalk/crossing line, then along it to the far edge (crossing
  /// a road at the zebra when that line is a crossing). Built once after [place].
  /// Empty on tiles with no buildings or no walkable lines — callers fall back to
  /// the plain sidewalk/crossing splines.
  late final List<PedSpawnRoute> buildingExitRoutes = _buildExitRoutes();

  List<PedSpawnRoute> _buildExitRoutes() {
    final footprints = decoration.buildingFootprints;
    if (footprints.isEmpty) return const [];
    // Each candidate line, tagged with whether stepping onto it crosses a road.
    final lines = <(Spline, bool)>[
      for (final s in sidewalkPaths) (s, false),
      for (final s in crossingPaths) (s, true),
    ];
    if (lines.isEmpty) return const [];

    final routes = <PedSpawnRoute>[];
    for (final b in footprints) {
      final c = b.center;
      Spline? best;
      bool bestCrosses = false;
      Vector2 join = Vector2.zero();
      double bestD2 = double.infinity;
      for (final (line, crosses) in lines) {
        for (int i = 0; i <= 12; i++) {
          final p = line.evaluate(i / 12);
          final d2 = (p.x - c.dx) * (p.x - c.dx) + (p.y - c.dy) * (p.y - c.dy);
          if (d2 < bestD2) {
            bestD2 = d2;
            best = line;
            bestCrosses = crosses;
            join = p;
          }
        }
      }
      if (best == null) continue;
      // Door: the point on the building edge nearest the join (so they step out
      // toward the sidewalk), nudged just outside the footprint.
      final door = Vector2(
        join.x.clamp(b.left, b.right),
        join.y.clamp(b.top, b.bottom),
      );
      final out = (join - door);
      if (out.length2 > 1) door.add(out.normalized() * 3);
      // Walk to the far end of the line (the longer way → it crosses the road
      // when the line is a crossing).
      final e0 = best.evaluate(0.0), e1 = best.evaluate(1.0);
      final far = e0.distanceToSquared(join) >= e1.distanceToSquared(join)
          ? e0
          : e1;
      final mid = (join + far) * 0.5;
      routes.add(PedSpawnRoute(
        Spline([door, join, mid, far]),
        crossesRoad: bestCrosses,
      ));
    }
    return routes;
  }

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
    if (!kDebugMode || !DebugState.showDebug) return;

    // Player paths — bright green
    final playerPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (final s in playerPaths) {
      _drawSplinePath(canvas, s, playerPaint);
    }

    // Extra player options not in [playerPaths] (e.g. turn-fork branches) —
    // dimmer green so they read as "available but not the default lane path".
    final extraPaint = Paint()
      ..color = const Color(0x8800E676)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final s in debugExtraSplines) {
      _drawSplinePath(canvas, s, extraPaint);
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
    List<Pedestrian> pedestrians,
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
