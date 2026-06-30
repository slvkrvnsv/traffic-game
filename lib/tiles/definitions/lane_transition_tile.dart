import 'dart:math' as math;
import 'dart:ui';
import 'package:flame/components.dart';
import '../../core/constants.dart';
import '../../core/game_bus.dart';
import '../../core/spline.dart';
import '../../cars/npc_car.dart';
import '../../cars/player_car.dart';
import '../../pedestrians/pedestrian.dart';
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
///     hand-off keeps the player in whichever lane they entered. The player merges
///     with the UNIVERSAL lane change (drag left onto the inner lane — the same
///     offset-cap-commit SLIDE every multi-lane tile uses); steering is only gated
///     off near the pinch where the lanes coincide (see [allowsLaneChangeAt]). A
///     player who never drags is delivered in by the merging lane's own geometry.
///     The merge is announced as "Merge left".
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
  LaneTransitionTile(
      {required this.merging, ScenarioBase? scenario, super.locale})
      : super(
          tileType:
              merging ? TileType.laneMerge : TileType.laneExtend,
          scenario: scenario ?? FreeDriveScenario(),
        );

  /// True = 2→1 lane drop (merge); false = 1→2 lane addition (extend).
  final bool merging;

  static void register() {
    // Free-drive spawnable: the lane-match chainer places a merge only after a
    // 2-lane exit and an extend only after a 1-lane exit, so each connector
    // always seams onto the lane count it transitions from.
    TileRegistry.register(
      TileType.laneMerge,
      (ctx) => LaneTransitionTile(
        merging: true,
        scenario: ScenarioRegistry.forTile(TileType.laneMerge, rng: ctx.rng),
        locale: ctx.locale,
      ),
      entryLanes: 2, // 2→1 lane drop
      exitLanes: 1,
    );
    TileRegistry.register(
      TileType.laneExtend,
      (ctx) => LaneTransitionTile(
        merging: false,
        scenario: ScenarioRegistry.forTile(TileType.laneExtend, rng: ctx.rng),
        locale: ctx.locale,
      ),
      entryLanes: 1, // 1→2 lane addition
      exitLanes: 2,
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

  /// Centre x of the ONCOMING outer lane — the mirror of [_outerLaneX] about the
  /// centreline (560 merged → 480 wide). So oncoming traffic sees the opposite
  /// transition: a merge tile WIDENS for oncoming, a widen tile NARROWS.
  double _oncomingOuterX(double y) =>
      _oncomingInnerX - _openness(y) * kLaneWidth;

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

  /// The oncoming outer lane — the mirror of [_mergeLane] about the centreline,
  /// travelling top → bottom like [_oncoming]. Lets oncoming traffic use both
  /// lanes where the road is wide (the markings already mirror it).
  Spline _oncomingOuterLane() {
    const n = 24;
    return Spline([
      for (int i = 0; i <= n; i++)
        () {
          final y = kTileSize * (i / n); // top (0) → bottom (1200)
          return Vector2(_oncomingOuterX(y), y);
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

  // NPC lane splines as fields so [npcPaths] and [npcLanes] share identity. The
  // outer lanes mirror each other about the centreline, so oncoming traffic gets
  // the opposite transition for free.
  late final Spline _npcOncomingInner = _oncoming();
  late final Spline _npcOncomingOuter = _oncomingOuterLane();
  late final Spline _npcThrough = _through();
  late final Spline _npcOuter = _mergeLane();

  @override
  late final List<Spline> npcPaths =
      [_npcOncomingInner, _npcOncomingOuter, _npcThrough, _npcOuter];

  // Group the two lanes that are COINCIDENT at their spawn entry (so the spawner
  // picks one at random instead of dropping two overlapping cars); keep the
  // separated pair as distinct spawn lanes. On each tile exactly one direction
  // is coincident at entry — the side whose outer lane is opening from there.
  @override
  late final List<List<Spline>> npcLanes = merging
      // Merge: oncoming WIDENS (its lanes coincide at the top entry) → group it.
      // Player side is separated at its (bottom) entry → distinct lanes.
      ? [
          [_npcOncomingInner, _npcOncomingOuter],
          [_npcThrough],
          [_npcOuter],
        ]
      // Widen: player side opens from its (bottom) entry → grouped (per-car
      // straight/diverge). Oncoming NARROWS (separated at the top entry) → its
      // outer lane is distinct and yields into the inner (see updateNpcSensors).
      : [
          [_npcOncomingInner],
          [_npcOncomingOuter],
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

  /// The merge-yield gives way to a surviving-lane car unless that car is already
  /// THIS far BEHIND us (tile-local Y) — then we've won the zipper and drive on.
  /// MUST stay equal to [TileBase._gapAhead]'s lead-detection cone threshold
  /// (`kCarLength * 0.5`): the merging car stops yielding to a surviving car at
  /// exactly the point that car starts seeing the merging car as a lead and brakes
  /// for it. Aligned, responsibility hands off cleanly — no gap where the merging
  /// car yields to a car BEHIND it while that car simultaneously brakes for it (a
  /// mutual stall that froze the merging car in the taper, blinker on, FOREVER —
  /// the reported "stuck on the merge spot" bug), and no band where both yield. The
  /// old full `kCarLength` left exactly that 26u deadlock band.
  static const double _mergeLeadMargin = kCarLength * 0.5;

  bool _taskShown = false;
  bool _playerEverMerged = false;
  bool _mergeCleared = false;

  @override
  void updateNpcSensors(
    double dt,
    PlayerCar playerCar,
    List<NpcCar> allNpcs,
    List<Pedestrian> pedestrians, {
    bool gradePlayer = true,
  }) {
    // ordinary lead-car gaps (no crossing peds on a connector)
    super.updateNpcSensors(dt, playerCar, allNpcs, pedestrians);

    if (merging) {
      // Player-direction merge (north): the ending outer lane gives way to
      // through traffic (through NPCs AND the player) and its cars signal left.
      final playerOnThrough = identical(playerCar.spline, playerPaths.first);
      _applyConvergenceYield(
        _npcOuter,
        _npcThrough,
        northbound: true,
        signal: true,
        extraSurvivingY:
            playerOnThrough ? [worldToLocal(playerCar.position).y] : const [],
      );
      if (gradePlayer) _updatePlayerMergeGrading(playerCar);
    } else {
      // Widen: the oncoming side is the mirror — its outer lane NARROWS, so the
      // SAME yield keeps oncoming cars from phasing through each other as they
      // converge. NPC-only by design: no player, no grading, no sign/signal.
      _applyConvergenceYield(
        _npcOncomingOuter,
        _npcOncomingInner,
        northbound: false,
        signal: false,
      );
    }
  }

  /// Virtual-lead "tuck in behind" yield: a car on the ENDING (narrowing) lane
  /// gives way to traffic on the SURVIVING lane so the two never pass through
  /// each other where they converge. Generic over travel direction
  /// ([northbound] — the player merges north, oncoming traffic south) and
  /// whether the ending cars signal left (only the player-facing merge does; the
  /// oncoming mirror is silent). Lanes are matched by spline identity so it's
  /// order-independent.
  void _applyConvergenceYield(
    Spline endingLane,
    Spline survivingLane, {
    required bool northbound,
    required bool signal,
    Iterable<double> extraSurvivingY = const [],
  }) {
    final survY = <double>[
      for (final npc in npcs)
        if (identical(npc.spline, survivingLane)) worldToLocal(npc.position).y,
      ...extraSurvivingY,
    ];
    for (final npc in npcs) {
      if (!identical(npc.spline, endingLane)) continue;
      final myY = worldToLocal(npc.position).y;

      if (signal) {
        // Signal left across the move (with an advance-warning lead-in), drop
        // it once merged.
        npc.brain.signalLeftForMerge =
            myY > _taperEndY && myY <= _taperStartY + kIndicatorSignalDistance;
      }

      // Yield only where the lanes actually converge (the taper). Outside it the
      // outer lane is fully its own (must not freeze at the wide end) or has
      // merged (same-lane following from super takes over).
      if (myY > _taperStartY || myY <= _taperEndY) continue;

      double gap = double.infinity;
      for (final vY in survY) {
        final ahead = northbound ? (myY - vY) : (vY - myY); // >0 ⇒ they're ahead
        // The surviving car is already behind us (and far enough back that IT now
        // brakes for us, see [_mergeLeadMargin]) → we've won the spot, drive on.
        if (ahead < -_mergeLeadMargin) continue;
        final g = (ahead - kCarLength).clamp(0.0, double.infinity);
        if (g < gap) gap = g;
      }
      if (gap.isFinite) {
        final existing = npc.brain.leadCarDistance;
        npc.brain.leadCarDistance =
            existing == null ? gap : math.min(existing, gap);
      }
    }
  }

  /// Passive, lane-scoped player grading (merge tile only). "Actively merging" =
  /// in the ending lane AND not yet past the pinch — the "Merge left" task and
  /// the cut-off fault both key off it, so a player who has already merged in
  /// can't be flagged for an "unsafe merge" later. (The blinker is manual now —
  /// the tile no longer forces it.)
  void _updatePlayerMergeGrading(PlayerCar playerCar) {
    final playerMerging = identical(playerCar.spline, playerPaths[1]);
    final playerY = worldToLocal(playerCar.position).y;
    final activelyMerging = playerMerging && playerY > _taperEndY;

    final s = scenario;
    if (s is MergeScenario) s.playerIsMerging = activelyMerging;
    if (playerMerging) _playerEverMerged = true;

    if (activelyMerging != _taskShown) {
      _taskShown = activelyMerging;
      GameBus.instance.emit(ManeuverAnnouncedEvent(
          maneuver: null, label: activelyMerging ? 'Merge left' : null));
    }

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

  // Grass margins clear of the widest part of the tapering road (max half-width
  // = kLaneWidth*2 + pavement ⇒ outer edge at cx±200), with a little slack.
  @override
  List<Rect> get decorationZones => const [
        Rect.fromLTWH(0, 0, 380, kTileSize),
        Rect.fromLTWH(820, 0, kTileSize - 820, kTileSize),
      ];

  @override
  void render(Canvas canvas) {
    _drawGround(canvas);
    _drawPavement(canvas);
    _drawRoad(canvas);
    _drawMarkings(canvas);
    // Sign on the player's right shoulder at the tile's beginning (the player
    // enters at the bottom) — the lane-ends warning on a merge, its mirror
    // (lane added) on a widen. Oncoming side never signed.
    RoadSigns.draw(
      canvas,
      merging ? RoadSign.laneEndsRight : RoadSign.laneAddedRight,
      const Offset(868, 1100),
      r: 35,
    );
    drawDecorations(canvas);
    debugRenderSplines(canvas);
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kTileSize, kTileSize),
      Paint()..color = groundColor,
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
    const startInset = 60.0, endInset = 30.0; // keep dashes clear of the seams
    final yLimit = kTileSize - endInset;
    double y = startInset;
    while (y < yLimit) {
      // Density follows how much outer lane is left: full lane → ordinary
      // divider, half gone → already the dense lane-drop dots (full density by
      // the taper mid-point). Applied on BOTH sides — the outer lane is ending
      // for traffic going one way and *beginning* for the other (which reads it
      // as a de-densifying line), but either way the dots mark the narrow end.
      final f = ((1.0 - _openness(y)) / 0.5).clamp(0.0, 1.0);
      final dash = normalDash + (denseDash - normalDash) * f;
      final gap = normalGap + (denseGap - normalGap) * f;
      final yEnd = (y + dash).clamp(0.0, yLimit);
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
    // Three advance arrows spread as wide as the approach allows, from the
    // taper edge (back 0) out to the seam guard — the widest even spacing that
    // still fits three arrows before the taper. The extend tile's approach
    // (above the taper) is shorter than the merge tile's (below it), so its
    // spacing is a touch tighter; both are maxed to the lane.
    final backs = merging
        ? const [0.0, 130.0, 260.0]
        : const [0.0, 105.0, 210.0];
    // Nudge the whole group 50px toward the taper edge — north on the merge
    // tile, its mirror (south) on the widen tile — applied via [backDir] so
    // both stay symmetric and keep all three arrows on-tile.
    const groupShift = 50.0;
    for (final back in backs) {
      final y = approachEdgeY + backDir * (back - groupShift);
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
