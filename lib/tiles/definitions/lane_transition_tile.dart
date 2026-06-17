import 'dart:math' as math;
import 'dart:ui';
import 'package:flame/components.dart';
import '../../core/constants.dart';
import '../../core/game_bus.dart';
import '../../core/spline.dart';
import '../../cars/npc_car.dart';
import '../../cars/player_car.dart';
import '../road_signs.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../scenarios/scenario_base.dart';
import '../scenarios/scenario_registry.dart';
import '../scenarios/free_drive_scenario.dart';
import '../scenarios/merge_scenario.dart';

/// A lane-transition connector between the 2-lane straight and the 1-lane
/// straight.
///
/// Two configurations, controlled by [merging]:
///   * **merge (2→1):** the player's outer/right lane ends and merges left into
///     the inner lane (the MUTCD "Right Lane Ends" situation). Two player paths
///     — the through lane (640) and the merging lane (720→640) — so the seam
///     hand-off keeps the player in whichever lane they entered. Lane-change is
///     OFF (it's a commanded transition, not free steering), and the merge is
///     announced as "Merge left".
///   * **extend (1→2):** a lane is added on the right (1→2) — the north-south
///     mirror of a merge. The player simply continues in the inner lane; the
///     new lane opens to their right and is joined on the following 2-lane
///     straight. No task, nothing graded ("just go").
///
/// Both ends seam on the inner lane (x=640 player / x=560 oncoming), so the
/// tile drops cleanly between the 2-lane and 1-lane straights. The road is a
/// symmetric trapezoid about the centreline (x=600): the outer lanes on *both*
/// sides taper, so the corridor narrows (merge) or widens (extend) evenly.
///
/// Coordinate system: origin = bottom-left of tile. X → right, Y → up (forward).
class LaneTransitionTile extends TileBase {
  LaneTransitionTile({required this.merging, ScenarioBase? scenario})
      : super(
          tileType:
              merging ? TileType.laneMerge : TileType.laneExtend,
          scenario: scenario ?? FreeDriveScenario(),
        );

  /// True = 2→1 lane drop (merge); false = 1→2 lane addition (extend).
  final bool merging;

  static void register() {
    // Course-only (spawnable: false): connectors only seam correctly when
    // chained through the 1-lane straight, not dropped into random free drive.
    TileRegistry.register(
      TileType.laneMerge,
      (ctx) => LaneTransitionTile(
        merging: true,
        scenario: ScenarioRegistry.forTile(TileType.laneMerge, rng: ctx.rng),
      ),
      spawnable: false,
    );
    TileRegistry.register(
      TileType.laneExtend,
      (ctx) => LaneTransitionTile(
        merging: false,
        scenario: ScenarioRegistry.forTile(TileType.laneExtend, rng: ctx.rng),
      ),
      spawnable: false,
    );
  }

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  static const double _cx = kTileSize / 2; // 600 — centreline
  static const double _playerInnerX = _cx + kLaneWidth * 0.5; // 640 — seam lane
  static const double _oncomingInnerX = _cx - kLaneWidth * 0.5; // 560

  // ---------------------------------------------------------------------------
  // Lateral taper profile — shared by the merging spline AND the rendered kerb,
  // so the lane and the road edge move together. `openness` is 1 where the
  // outer lane is fully present and 0 where it has merged away, eased with a
  // smoothstep over a y-window. It is strictly monotonic, so the lane glides
  // straight in — never bowing the wrong way before it merges (which is what
  // hand-placed Catmull-Rom control points were doing).
  // ---------------------------------------------------------------------------
  static const double _taperStartY = 900.0; // wide-end side of the taper window
  static const double _taperEndY = 250.0; // narrow-end side of the taper window

  /// 1 = two lanes (outer lane present), 0 = one lane (merged). The wide end is
  /// the bottom for a merge and the top for an extend (the N-S mirror).
  double _openness(double y) {
    double s;
    if (y >= _taperStartY) {
      s = 1.0; // bottom hold
    } else if (y <= _taperEndY) {
      s = 0.0; // top hold
    } else {
      final t = (y - _taperEndY) / (_taperStartY - _taperEndY);
      s = t * t * (3 - 2 * t); // smoothstep
    }
    return merging ? s : 1.0 - s;
  }

  /// Centre x of the outer/merging lane at tile-local [y]: 640 (merged) → 720.
  double _outerLaneX(double y) => _playerInnerX + _openness(y) * kLaneWidth;

  /// Half road-width at [y]: one lane (kLaneWidth) merged → two (kLaneWidth*2).
  double _roadHalfAt(double y) => kLaneWidth * (1 + _openness(y));

  /// Player straight-through inner lane (always present, both ends at 640).
  static Spline _through() => Spline([
        Vector2(_playerInnerX, kTileSize),
        Vector2(_playerInnerX, kTileSize * 0.66),
        Vector2(_playerInnerX, kTileSize * 0.33),
        Vector2(_playerInnerX, 0),
      ]);

  /// Oncoming inner lane (always present), travelling top → bottom.
  static Spline _oncoming() => Spline([
        Vector2(_oncomingInnerX, 0),
        Vector2(_oncomingInnerX, kTileSize * 0.33),
        Vector2(_oncomingInnerX, kTileSize * 0.66),
        Vector2(_oncomingInnerX, kTileSize),
      ]);

  /// The merging lane (merge tiles only): the outer lane eased smoothly into
  /// the inner lane along the shared taper profile. Densely sampled so the
  /// spline hugs the curve with no overshoot.
  Spline _mergeLane() {
    const n = 24;
    return Spline([
      for (int i = 0; i <= n; i++)
        () {
          final y = kTileSize * (1 - i / n); // bottom (1200) → top (0)
          return Vector2(_outerLaneX(y), y);
        }(),
    ]);
  }

  // Both configs carry the through lane plus the tapered outer lane; [_mergeLane]
  // adapts its direction via [_openness] — on a merge the outer lane merges in
  // (720→640), on a widen it diverges out (640→720) as the new lane opens.
  // [_through] stays first so a hand-off / position tie defaults the player to
  // driving straight through rather than into the outer lane.
  @override
  late final List<Spline> playerPaths = [_through(), _mergeLane()];

  // NPC lane splines as fields so [npcPaths] and [npcLanes] share identity.
  late final Spline _npcOncoming = _oncoming();
  late final Spline _npcThrough = _through();
  late final Spline _npcOuter = _mergeLane();

  @override
  late final List<Spline> npcPaths = [_npcOncoming, _npcThrough, _npcOuter];

  @override
  late final List<List<Spline>> npcLanes = merging
      // Merge: the outer lane is its own spawn point (cars start in it and merge
      // in), so one lane per path — keeps laneIndex oncoming=0/through=1/merge=2
      // for the merge-yield in updateNpcSensors.
      ? [
          [_npcOncoming],
          [_npcThrough],
          [_npcOuter],
        ]
      // Widen: the new lane opens FROM the entry, so each car arriving in the
      // inner lane independently rolls "keep straight" vs "take the new lane" —
      // one entry lane offering both movements (per-car choice, like a junction).
      : [
          [_npcOncoming],
          [_npcThrough, _npcOuter],
        ];

  // Steering is positional only on the MERGE (see [allowsLaneChangeAt]); the
  // widen is on the whole tile. NPCs entering at the shared seam randomly
  // continue straight or take the outer lane via TileManager's seam matcher.
  @override
  bool allowsLaneChangeAt(Vector2 localPos) {
    // Widen: on from the start — you can line up for the new lane as it opens.
    if (!merging) return allowsLaneChange;
    // Merge: on while the two lanes are still meaningfully separated; off once
    // they converge near the end, so the car self-centres onto the single lane.
    return _openness(localPos.y) * kLaneWidth >= kSteerEnableSeparation;
  }

  @override
  Spline? splineSteerTargetAt(Vector2 localPos, int direction) {
    // The fork is wherever the two player lanes are still near-coincident — the
    // START of a widen (outer lane about to diverge out) AND the END of a merge
    // (outer lane just converged in). Same condition for both: the outer lane's
    // separation from the inner one is below a real lane-width. Past that
    // they're clearly two lanes → ordinary offset lane change ("loosens").
    if (_openness(localPos.y) * kLaneWidth >= kMinLaneCommitSeparation) {
      return null;
    }
    // playerPaths = [through (inner/left), outer lane (right)] — a drag picks
    // the spline on that side; the spline geometry merges in / diverges out.
    return direction > 0 ? playerPaths[1] : playerPaths[0];
  }

  // The "Merge left" task is announced dynamically by [updateNpcSensors] — only
  // while the player is actually in the ending (right) lane — so there's no
  // static label that would show even when they're already in the through lane.
  @override
  String? get taskLabel => null;

  @override
  Vector2 get entryAnchor => Vector2(_playerInnerX, kTileSize);

  @override
  Vector2 get exitAnchor => Vector2(_playerInnerX, 0);

  // ---------------------------------------------------------------------------
  // Merge right-of-way + grading (merge tiles only)
  //
  // NPC half: a car on the ending (outer) lane gives way to through traffic
  // (through NPCs *and* the player) where the lanes converge, treating a
  // conflicting through vehicle as a virtual lead car so the gas/brake layer
  // eases it in behind for a gap instead of barging across. It signals left the
  // whole way over. Yield is gated to the taper region so a car running
  // parallel to through traffic at the wide entry never freezes (the lanes are
  // still fully separate there).
  //
  // Player half: passive, lane-scoped grading. The "Merge left" task and the
  // cut-off fault only apply while the player is in the ending lane; in the
  // through lane they have priority and nothing is tested ("just go").
  // ---------------------------------------------------------------------------

  /// NPC lane indices — npcPaths order is [oncoming, through, merge].
  static const int _mergeLaneIndex = 2;
  static const int _throughLaneIndex = 1;

  /// A merging car may slot ahead of a through car only once it's at least this
  /// far ahead (tile-local Y); otherwise it gives way and tucks in behind.
  static const double _mergeLeadMargin = kCarLength;

  bool _taskShown = false;
  bool _playerEverMerged = false;
  bool _mergeCleared = false;

  @override
  void updateNpcSensors(
    double dt,
    PlayerCar playerCar,
    List<NpcCar> allNpcs,
  ) {
    super.updateNpcSensors(dt, playerCar, allNpcs); // ordinary lead-car gaps
    if (!merging) return;

    final mergeLane = playerPaths[1];
    final throughLane = playerPaths.first;
    final playerMerging = identical(playerCar.spline, mergeLane);
    final playerOnThrough = identical(playerCar.spline, throughLane);
    final playerY = worldToLocal(playerCar.position).y;

    // Through-lane vehicles (tile-local Y, northbound) a merging car gives way
    // to: through NPCs, plus the player when in the through lane.
    final throughY = <double>[
      for (final npc in npcs)
        if (npc.laneIndex == _throughLaneIndex) worldToLocal(npc.position).y,
      if (playerOnThrough) playerY,
    ];

    for (final npc in npcs) {
      if (npc.laneIndex != _mergeLaneIndex) continue;
      final myY = worldToLocal(npc.position).y;

      // Signal left across the move (incl. an advance-warning lead-in before the
      // taper), drop it once merged.
      npc.brain.signalLeftForMerge =
          myY > _taperEndY && myY <= _taperStartY + kIndicatorSignalDistance;

      // Yield only where the lanes actually converge. Above [_taperStartY] the
      // outer lane is fully its own (a car parallel to through traffic at the
      // wide entry must NOT freeze); at/below [_taperEndY] it has merged and
      // ordinary same-lane following (from super) takes over.
      if (myY > _taperStartY || myY <= _taperEndY) continue;

      double mergeGap = double.infinity;
      for (final vY in throughY) {
        final ahead = myY - vY; // >0 ⇒ through car is ahead (north) of us
        if (ahead < -_mergeLeadMargin) continue; // we're clearly in front → go
        final gap = (ahead - kCarLength).clamp(0.0, double.infinity);
        if (gap < mergeGap) mergeGap = gap;
      }
      if (mergeGap.isFinite) {
        final existing = npc.brain.leadCarDistance;
        npc.brain.leadCarDistance =
            existing == null ? mergeGap : math.min(existing, mergeGap);
      }
    }

    // ---- Player grading (passive, lane-scoped) ----
    // "Actively merging" = in the ending lane AND not yet past the pinch. The
    // fault, the task and the auto-signal all key off this one condition, so a
    // player who has already merged in (driving the last stretch of the tile in
    // the single lane, still on the merge spline) can no longer be flagged for
    // an "unsafe merge" — which otherwise read as a fault on a later tile.
    final activelyMerging = playerMerging && playerY > _taperEndY;
    final s = scenario;
    if (s is MergeScenario) s.playerIsMerging = activelyMerging;
    if (playerMerging) _playerEverMerged = true;

    // Dynamic task: "Merge left" only while actively merging.
    final wantTask = activelyMerging;
    if (wantTask != _taskShown) {
      _taskShown = wantTask;
      GameBus.instance.emit(ManeuverAnnouncedEvent(
          maneuver: null, label: wantTask ? 'Merge left' : null));
    }
    // Auto-signal left for the whole commanded merge — from the moment the task
    // appears, not just when the lane bends (mirrors the NPC's signalLeftForMerge).
    playerCar.forceLeftIndicator = wantTask;

    // Pass: the player took the ending lane and merged in past the pinch without
    // a fault (a cut-off would already have failed via onDriverReaction).
    if (!_mergeCleared && _playerEverMerged && playerY <= _taperEndY) {
      _mergeCleared = true;
      s.onSafelyCleared();
      if (s.result.status == ScenarioStatus.passed) {
        GameBus.instance.emit(RulePassedEvent());
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  @override
  void render(Canvas canvas) {
    _drawGround(canvas);
    _drawPavement(canvas);
    _drawRoad(canvas);
    _drawMarkings(canvas);
    // Sign on the player's right shoulder near the entry — the lane-ends warning
    // on a merge, its mirror (lane added) on a widen. Oncoming side never signed.
    RoadSigns.draw(
      canvas,
      merging ? RoadSign.laneEndsRight : RoadSign.laneAddedRight,
      const Offset(868, 980),
    );
    debugRenderSplines(canvas);
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kTileSize, kTileSize),
      Paint()..color = const Color(0xFF4CAF50),
    );
  }

  /// Closed road polygon whose left/right kerbs follow the taper profile,
  /// widened outward by [extra] (used for the pavement border). Sampled finely
  /// so the curved kerb reads as a smooth taper, not a hard diagonal.
  static const int _edgeSamples = 48;

  Path _roadBand(double extra) {
    final path = Path();
    for (int i = 0; i <= _edgeSamples; i++) {
      final y = kTileSize * i / _edgeSamples;
      final x = _cx + _roadHalfAt(y) + extra;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    for (int i = _edgeSamples; i >= 0; i--) {
      final y = kTileSize * i / _edgeSamples;
      path.lineTo(_cx - _roadHalfAt(y) - extra, y);
    }
    return path..close();
  }

  void _drawPavement(Canvas canvas) {
    canvas.drawPath(
        _roadBand(kPavementWidth), Paint()..color = const Color(0xFFBDBDBD));
  }

  void _drawRoad(Canvas canvas) {
    canvas.drawPath(_roadBand(0), Paint()..color = const Color(0xFF424242));
  }

  void _drawMarkings(Canvas canvas) {
    // Solid double-yellow centreline (vertical — the taper is symmetric).
    final yellow = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3;
    canvas.drawLine(Offset(_cx - 4, 0), Offset(_cx - 4, kTileSize), yellow);
    canvas.drawLine(Offset(_cx + 4, 0), Offset(_cx + 4, kTileSize), yellow);

    // The lane line sits at the FIXED lane boundary (the surviving lane's
    // edge); the kerb tapers in to meet it (MUTCD lane-reduction markings).
    // Player side (right) ends on a merge tile; oncoming side (left) ends on an
    // extend tile. The ending side gets a dense dotted line + merge arrows.
    _drawLaneBoundary(canvas,
        boundaryX: _playerInnerX + kLaneWidth * 0.5, // 680
        ending: merging,
        travelDirY: -1, // player heads north (up)
        mergeDirX: -1); // merges left toward the centreline
    _drawLaneBoundary(canvas,
        boundaryX: _oncomingInnerX - kLaneWidth * 0.5, // 520
        ending: !merging,
        travelDirY: 1, // oncoming heads south (down)
        mergeDirX: 1); // merges toward the centreline (right)
  }

  /// Lane line at the fixed [boundaryX] between a surviving inner lane and the
  /// outer lane. An ENDING lane's line **starts as an ordinary lane divider** at
  /// the wide end (where it seams onto the 2-lane road) and *gradually* tightens
  /// into the dense MUTCD lane-drop dots as the outer lane pinches away — so the
  /// "yield / lane ending" reading builds up toward the merge point rather than
  /// being on from the first metre. A lane merely being added gets a plain dash.
  /// The line is only drawn where the outer lane actually exists.
  void _drawLaneBoundary(Canvas canvas,
      {required double boundaryX,
      required bool ending,
      required double travelDirY,
      required double mergeDirX}) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 3; // match the straight tiles' lane lines
    const normalDash = 40.0, normalGap = 40.0; // ordinary divider (2-lane road)
    const denseDash = 22.0, denseGap = 14.0; // lane-drop warning dots
    double y = 0;
    while (y < kTileSize) {
      // Density follows how much outer lane is left: full lane → ordinary
      // divider, half gone → already the dense lane-drop dots (full density by
      // the taper mid-point). Applied on BOTH sides — the outer lane is ending
      // for traffic going one way and *beginning* for the other (which reads it
      // as a de-densifying line), but either way the dots mark the narrow end.
      final f = ((1.0 - _openness(y)) / 0.5).clamp(0.0, 1.0);
      final dash = normalDash + (denseDash - normalDash) * f;
      final gap = normalGap + (denseGap - normalGap) * f;
      final yEnd = (y + dash).clamp(0.0, kTileSize);
      if (_openness((y + yEnd) / 2) > 0.04) {
        canvas.drawLine(Offset(boundaryX, y), Offset(boundaryX, yEnd), paint);
      }
      y += dash + gap;
    }
    if (ending) _drawMergeArrows(canvas, boundaryX, travelDirY, mergeDirX);
  }

  /// White merge arrows in the full ending lane *before* the taper begins —
  /// the advance warning a driver reads while there's still room to move over.
  /// Stepped back from the taper edge into the approach (which side that is
  /// depends on the travel direction).
  void _drawMergeArrows(
      Canvas canvas, double boundaryX, double travelDirY, double mergeDirX) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;
    // Approach edge of the taper, and the direction back into the approach.
    final approachEdgeY = merging ? _taperStartY : _taperEndY;
    final backDir = merging ? 1.0 : -1.0;
    for (final back in const [30.0, 130.0, 230.0]) {
      final y = approachEdgeY + backDir * back;
      if (y < 40 || y > kTileSize - 40) continue;
      final arrowX = boundaryX - mergeDirX * kLaneWidth * 0.5 * _openness(y);
      // Mostly along travel, leaning the merge way — reads as "move over".
      _drawArrow(canvas, Offset(arrowX, y),
          Offset(mergeDirX * 0.7, travelDirY), paint);
    }
  }

  void _drawArrow(Canvas canvas, Offset pos, Offset dir, Paint fill) {
    final dl = dir.distance;
    final u = dl == 0 ? const Offset(0, -1) : Offset(dir.dx / dl, dir.dy / dl);
    final perp = Offset(-u.dy, u.dx);
    const head = 28.0, halfW = 13.0, stem = 30.0;
    final tip = pos + u * head;
    final baseL = pos + perp * halfW;
    final baseR = pos - perp * halfW;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(baseL.dx, baseL.dy)
        ..lineTo(baseR.dx, baseR.dy)
        ..close(),
      fill,
    );
    canvas.drawLine(
      pos,
      pos - u * stem,
      Paint()
        ..color = fill.color
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round,
    );
  }

}
