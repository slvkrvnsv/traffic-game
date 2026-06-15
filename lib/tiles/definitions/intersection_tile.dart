import 'dart:math' as math;
import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../core/maneuver.dart';
import '../../core/spline.dart';
import '../../core/game_bus.dart';
import '../../cars/npc_car.dart';
import '../../cars/player_car.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../scenarios/scenario_base.dart';
import '../scenarios/scenario_registry.dart';
import '../scenarios/yield_scenario.dart';

/// Cardinal heading of a vehicle travelling through the intersection.
/// Ordered clockwise so `(index + 1) % 4` = next clockwise neighbour.
enum Heading { north, east, south, west }

extension _HeadingX on Heading {
  /// The heading a driver with *this* heading must yield to.
  ///
  /// In right-hand traffic, yield to the car approaching from your right.
  /// A driver heading N sees traffic coming from the east side of the
  /// intersection — those cars are W-bound (moving away to the west).
  /// So N yields to W, E yields to N, S yields to E, W yields to S:
  /// i.e. the *counter-clockwise* neighbour.
  Heading get yieldsTo =>
      Heading.values[(index - 1 + Heading.values.length) %
          Heading.values.length];

  /// The opposite approach (oncoming traffic).
  Heading get opposite => Heading.values[(index + 2) % Heading.values.length];
}

/// 4-way uncontrolled intersection.
///
/// In the canonical frame the player enters from the south; the commanded
/// [maneuver] decides whether the player path goes straight (exit north),
/// turns left (exit west) or right (exit east) — the corridor rotates
/// accordingly via tile placement. NPC traffic flows straight through in all
/// four cardinal directions.
///
/// Right-of-way is evaluated per *movement* (approach + path through the
/// box): two movements conflict when their paths actually cross or merge,
/// computed geometrically from the splines. On top of that: never enter an
/// occupied box, first-come-first-served, yield-to-the-right on ties, and a
/// left turn always gives way to oncoming traffic.
class IntersectionTile extends TileBase {
  IntersectionTile({this.maneuver = Maneuver.straight, ScenarioBase? scenario})
      : super(
          tileType: TileType.intersection4way,
          scenario: scenario ?? YieldScenario(),
        );

  /// The exam instruction for this tile.
  final Maneuver maneuver;

  @override
  Maneuver? get commandedManeuver => maneuver;

  static void register() {
    TileRegistry.register(
      TileType.intersection4way,
      (ctx) => IntersectionTile(
        maneuver: ctx.maneuver ??
            Maneuver.values[
                (ctx.rng ?? math.Random()).nextInt(Maneuver.values.length)],
        scenario:
            ScenarioRegistry.forTile(TileType.intersection4way, rng: ctx.rng),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------

  static const double _cx = kTileSize / 2;
  static const double _cy = kTileSize / 2;
  static const double _halfBox = kRoadWidth / 2;

  // Right-hand-drive lanes: you drive on the right side of your road.
  // Vertical road:
  //   N-bound (y decreasing) → player's right side → x = _cx + laneOffset
  //   S-bound (y increasing) → x = _cx - laneOffset
  // Horizontal road:
  //   E-bound (x increasing) → y = _cy + laneOffset
  //   W-bound (x decreasing) → y = _cy - laneOffset
  static const double _laneOffset = kLaneWidth * 0.5;
  static const double _nLaneX = _cx + _laneOffset; // 640
  static const double _sLaneX = _cx - _laneOffset; // 560
  static const double _eLaneY = _cy + _laneOffset; // 640
  static const double _wLaneY = _cy - _laneOffset; // 560

  /// Distance *before* the box (measured along the travel axis) within which
  /// an approaching car is considered a "threat" for right-of-way purposes.
  static const double _approachDistance = 260.0;

  /// Painted stop line offset from the conflict-box edge (world units).
  static const double _stopLineGap = 12.0;

  /// Tile-local Y of the player's stop line on the south approach. The yield
  /// rule is evaluated at this line, so the painted marking == the rule.
  static const double _playerStopLineY = _cy + _halfBox + _stopLineGap;

  /// Radius of the rounded curb drawn at each intersection corner.
  static const double _curbRadius = 72.0;

  // ---------------------------------------------------------------------------
  // Splines — one per NPC heading, plus the player's straight-through path.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Movement geometry.
  //
  // All movements are authored once for the *south approach* (entering
  // N-bound in the right-hand lane) and generated for the other three
  // approaches by the intersection's 4-fold rotational symmetry. Splines are
  // built once per tile instance — identity is stable (seam matching and the
  // conflict cache rely on it) and the arc-length LUT is only computed once.
  // ---------------------------------------------------------------------------

  /// Turn radius — a quarter arc tangent to both the approach and exit lanes.
  static const double _turnRadius = 80.0;

  /// Arc points sampled per quarter turn. Fine sampling keeps the control point
  /// just past the junction nearly straight ahead, so the junction tangent stays
  /// vertical and the path doesn't bow the wrong way before it bends.
  static const int _arcSteps = 8;

  /// Evenly-spaced points along a circular arc, inclusive of both endpoints.
  static List<Vector2> _arc(
      Vector2 center, double startDeg, double endDeg, int steps) {
    return [
      for (int i = 0; i <= steps; i++)
        () {
          final rad = (startDeg + (endDeg - startDeg) * (i / steps)) *
              math.pi /
              180.0;
          return Vector2(
            center.x + _turnRadius * math.cos(rad),
            center.y + _turnRadius * math.sin(rad),
          );
        }(),
    ];
  }

  /// Control points for a south-approach movement. Turns follow a quarter arc
  /// (radius [_turnRadius]) tangent to both the approach lane and the exit lane.
  /// The lead point sits on the lane centreline right before the arc so the
  /// straight-to-arc junction stays tangent-continuous.
  static List<Vector2> _southApproachPoints(Maneuver m) => switch (m) {
        // South → north, straight through.
        Maneuver.straight => [
            Vector2(_nLaneX, kTileSize),
            Vector2(_nLaneX, _cy + _halfBox + 40),
            Vector2(_nLaneX, _cy),
            Vector2(_nLaneX, 0),
          ],
        // South → west: arc centre (560, 640), entry 0° → exit -90°.
        Maneuver.left => [
            Vector2(_nLaneX, kTileSize),
            Vector2(_nLaneX, _cy + 300),
            Vector2(_nLaneX, _cy + 120), // lead on the centreline
            ..._arc(Vector2(_sLaneX, _eLaneY), 0, -90, _arcSteps),
            Vector2(_cx - 320, _wLaneY),
            Vector2(0, _wLaneY),
          ],
        // South → east: arc centre (720, 720), entry 180° → exit 270°.
        Maneuver.right => [
            Vector2(_nLaneX, kTileSize),
            Vector2(_nLaneX, _cy + 300),
            Vector2(_nLaneX, _cy + 160), // lead on the centreline
            ..._arc(Vector2(_nLaneX + _turnRadius, _cy + 120), 180, 270,
                _arcSteps),
            Vector2(_cx + 360, _eLaneY),
            Vector2(kTileSize, _eLaneY),
          ],
      };

  /// Rotate a tile-local point 90° clockwise about the tile centre,
  /// applied [k] times. Maps the south approach onto east (k=1),
  /// north (k=2) and west (k=3) — matching [Heading.values] order.
  static Vector2 _rotateQuarters(Vector2 p, int k) {
    var v = p;
    for (int i = 0; i < k; i++) {
      v = Vector2(kTileSize - v.y, v.x);
    }
    return v;
  }

  /// Player path through the box for the commanded maneuver — always the
  /// south approach.
  @override
  late final List<Spline> playerPaths = [
    Spline(_southApproachPoints(maneuver)),
  ];

  /// Spawnable NPC lanes, one per approach in [Heading.values] order
  /// (lane index == approach heading index). Each lane offers all three
  /// movements; the spawner picks one per car, so NPC traffic turns too.
  @override
  late final List<List<Spline>> npcLanes = [
    for (int k = 0; k < Heading.values.length; k++)
      [
        for (final m in Maneuver.values)
          Spline([
            for (final p in _southApproachPoints(m)) _rotateQuarters(p, k),
          ]),
      ],
  ];

  @override
  late final List<Spline> npcPaths = [for (final lane in npcLanes) ...lane];

  /// Maneuver of each NPC movement path (lane order is [Maneuver.values]).
  late final Map<Spline, Maneuver> _maneuverByPath = {
    for (final lane in npcLanes)
      for (int i = 0; i < lane.length; i++) lane[i]: Maneuver.values[i],
  };

  @override
  Vector2 get entryAnchor => Vector2(_nLaneX, kTileSize);

  @override
  Vector2 get exitAnchor => switch (maneuver) {
        Maneuver.straight => Vector2(_nLaneX, 0),
        Maneuver.left => Vector2(0, _wLaneY),
        Maneuver.right => Vector2(kTileSize, _eLaneY),
      };

  @override
  Vector2 get exitDirection => switch (maneuver) {
        Maneuver.straight => Vector2(0, -1),
        Maneuver.left => Vector2(-1, 0),
        Maneuver.right => Vector2(1, 0),
      };

  // ---------------------------------------------------------------------------
  // Right-of-way evaluation
  // ---------------------------------------------------------------------------

  /// Classifies where a vehicle sits relative to the conflict box along its
  /// own travel axis.
  ///
  /// - `approaching`: within [_approachDistance] on the entry side of the box.
  /// - `inBox`: currently occupying the conflict zone.
  /// - `past`: already exited on the far side — no longer a threat.
  /// - `far`: outside all zones (too far away to matter).
  _Zone _zoneOf(Heading heading, Vector2 localPos) {
    final dx = localPos.x - _cx;
    final dy = localPos.y - _cy;

    // Inside the conflict box.
    if (dx.abs() <= _halfBox && dy.abs() <= _halfBox) {
      return _Zone.inBox;
    }

    switch (heading) {
      case Heading.north: // moving -y; entry side is y > cy (dy > _halfBox)
        if (dy > _halfBox && dy < _halfBox + _approachDistance) {
          return _Zone.approaching;
        }
        if (dy < -_halfBox) return _Zone.past;
        return _Zone.far;
      case Heading.south: // moving +y; entry side is y < cy
        if (dy < -_halfBox && dy > -(_halfBox + _approachDistance)) {
          return _Zone.approaching;
        }
        if (dy > _halfBox) return _Zone.past;
        return _Zone.far;
      case Heading.east: // moving +x; entry side is x < cx
        if (dx < -_halfBox && dx > -(_halfBox + _approachDistance)) {
          return _Zone.approaching;
        }
        if (dx > _halfBox) return _Zone.past;
        return _Zone.far;
      case Heading.west: // moving -x; entry side is x > cx
        if (dx > _halfBox && dx < _halfBox + _approachDistance) {
          return _Zone.approaching;
        }
        if (dx < -_halfBox) return _Zone.past;
        return _Zone.far;
    }
  }

  // ---------------------------------------------------------------------------
  // Movement conflicts — geometric, derived from the actual paths.
  // ---------------------------------------------------------------------------

  /// Two paths conflict when they pass closer than this anywhere (crossing or
  /// merging). Parallel opposite lanes are kLaneWidth (80) apart, so anything
  /// under that with margin means a real crossing/merge point.
  static const double _conflictClearance = 50.0;

  /// Conflict results are symmetric and immutable per path pair — cached.
  final Map<(Spline, Spline), bool> _conflictCache = {};

  /// Whether two movements (approach heading + path) can collide in the box.
  /// Same-approach traffic is a queue, not a conflict (lead-car gap handles it).
  bool _movementsConflict(
      Heading approachA, Spline a, Heading approachB, Spline b) {
    if (approachA == approachB || identical(a, b)) return false;
    return _conflictCache.putIfAbsent((a, b), () => _pathsConflict(a, b));
  }

  /// Whether the player's commanded movement conflicts with approach [lane]'s
  /// straight-through movement. Exposed for tests only.
  @visibleForTesting
  bool playerConflictsWithLane(int lane) => _movementsConflict(Heading.north,
      playerPaths.first, Heading.values[lane], npcLanes[lane].first);

  /// Whether two NPC movements conflict — [laneA]/[laneB] are approach
  /// indices, [a]/[b] pick the maneuver within the lane. Tests only.
  @visibleForTesting
  bool npcMovementsConflict(int laneA, Maneuver a, int laneB, Maneuver b) =>
      _movementsConflict(
        Heading.values[laneA],
        npcLanes[laneA][a.index],
        Heading.values[laneB],
        npcLanes[laneB][b.index],
      );

  static bool _pathsConflict(Spline a, Spline b) {
    const samples = 40;
    final bPoints = [
      for (int j = 0; j <= samples; j++) b.evaluate(j / samples),
    ];
    for (int i = 0; i <= samples; i++) {
      final pa = a.evaluate(i / samples);
      for (final pb in bPoints) {
        if (pa.distanceTo(pb) < _conflictClearance) return true;
      }
    }
    return false;
  }

  /// Window (world units) within which two vehicles count as arriving together,
  /// so the yield-to-the-right tie-break applies instead of first-come-first.
  static const double _arrivalTieBand = 60.0;

  /// Whether the movement ([mine] approach, [myPath], [myManeuver]) at
  /// tile-local [myLocal] must give way to *any* conflicting traffic —
  /// looking at the whole intersection, not one car:
  ///   1. Never enter the box while a conflicting car occupies it (safety).
  ///   2. A left turn gives way to approaching oncoming traffic, always.
  ///   3. Let a conflicting car that clearly reached the box first proceed
  ///      (first-come-first-served, by distance remaining to the box).
  ///   4. On a near-simultaneous arrival, give way to the car on the right.
  ///      If that car has itself stopped (a symmetric stand-off) we proceed, so
  ///      the intersection can never dead-lock.
  bool _mustGiveWay(
    Heading mine,
    Spline myPath,
    Maneuver myManeuver,
    Vector2 myLocal,
    List<_VehicleSample> vehicles,
  ) {
    final myGap = _gapToStopLine(mine, myLocal);
    var tieYield = false;
    for (final v in vehicles) {
      if (!_movementsConflict(mine, myPath, v.heading, v.path)) continue;
      final z = _zoneOf(v.heading, v.localPos);
      if (z == _Zone.inBox) return true; // (1) box occupied — always wait
      if (z != _Zone.approaching) continue;
      if (myManeuver == Maneuver.left &&
          v.heading == mine.opposite &&
          v.speed > kStopSpeedThreshold) {
        return true; // (2) left turn yields to moving oncoming traffic
      }
      final vGap = _gapToStopLine(v.heading, v.localPos);
      if (vGap < myGap - _arrivalTieBand) return true; // (3) they're clearly first
      if ((vGap - myGap).abs() <= _arrivalTieBand &&
          v.heading == mine.yieldsTo &&
          v.speed > kStopSpeedThreshold) {
        tieYield = true; // (4) simultaneous → yield to the moving car on the right
      }
    }
    return tieYield;
  }

  /// Distance from [localPos] to this heading's painted stop line, measured
  /// along the travel axis. Positive while still approaching (before the line),
  /// negative once across it. Mirrors the geometry in [_drawStopLines].
  double _gapToStopLine(Heading heading, Vector2 localPos) {
    switch (heading) {
      case Heading.north:
        return localPos.y - (_cy + _halfBox + _stopLineGap);
      case Heading.south:
        return (_cy - _halfBox - _stopLineGap) - localPos.y;
      case Heading.east:
        return (_cx - _halfBox - _stopLineGap) - localPos.x;
      case Heading.west:
        return localPos.x - (_cx + _halfBox + _stopLineGap);
    }
  }

  // ---------------------------------------------------------------------------
  // NPC sensor wiring
  // ---------------------------------------------------------------------------

  @override
  void updateNpcSensors(
    double dt,
    PlayerCar playerCar,
    List<NpcCar> allNpcs,
  ) {
    super.updateNpcSensors(dt, playerCar, allNpcs); // lead-car gaps first

    // Collect every vehicle that sits on one of *this* tile's lanes together
    // with its heading, in tile-local coordinates.
    final samples = <_VehicleSample>[
      // Player always enters from the south in the canonical frame; its path
      // through the box depends on the commanded maneuver.
      _VehicleSample(
        heading: Heading.north,
        path: playerPaths.first,
        localPos: worldToLocal(playerCar.position),
        speed: playerCar.speed,
      ),
      // NPCs use their *actual* movement spline (may be a turn), so conflicts
      // reflect where each car is really going.
      for (final npc in npcs)
        if (npc.laneIndex >= 0 &&
            npc.laneIndex < Heading.values.length &&
            npc.spline != null)
          _VehicleSample(
            heading: Heading.values[npc.laneIndex],
            path: npc.spline!,
            localPos: worldToLocal(npc.position),
            speed: npc.speed,
          ),
    ];

    // For each NPC: only cars currently approaching the box need to decide
    // whether to yield. Cars already in the box or past it cruise through.
    for (final npc in npcs) {
      if (npc.laneIndex < 0 ||
          npc.laneIndex >= Heading.values.length ||
          npc.spline == null) {
        continue;
      }
      final heading = Heading.values[npc.laneIndex];
      final path = npc.spline!;
      final localPos = worldToLocal(npc.position);
      final myZone = _zoneOf(heading, localPos);

      if (myZone != _Zone.approaching) {
        // Not approaching → never required to yield. (stopTargetDistance was
        // already cleared by super.updateNpcSensors.)
        npc.brain.intersectionRuleActive = false;
        npc.brain.hasRightOfWay = true;
        continue;
      }

      final npcManeuver = _maneuverByPath[path] ?? Maneuver.straight;
      final threatened =
          _mustGiveWay(heading, path, npcManeuver, localPos, samples);
      npc.brain.intersectionRuleActive = threatened;
      npc.brain.hasRightOfWay = !threatened;
      // When yielding, stop at this approach's painted line.
      npc.brain.stopTargetDistance =
          threatened ? _gapToStopLine(heading, localPos) : null;
    }

    // The player is legitimately required to wait while approaching/inside the
    // box if a car it must yield to is threatening — used to exempt the stop
    // from the road-blocking penalty.
    final playerLocal = worldToLocal(playerCar.position);
    final pZone = _zoneOf(Heading.north, playerLocal);
    _playerMustWait =
        (pZone == _Zone.approaching || pZone == _Zone.inBox) &&
            _mustGiveWay(Heading.north, playerPaths.first, maneuver,
                playerLocal, samples);

    // Player yield-violation detection.
    _checkPlayerYield(playerCar, samples);
  }

  bool _playerMustWait = false;

  @override
  bool get playerMustWait => _playerMustWait;

  /// True once the player has left the conflict box on any side other than
  /// the south entry — i.e. the maneuver through the box is complete.
  bool _playerExitedBox(Vector2 local) {
    final dx = local.x - _cx;
    final dy = local.y - _cy;
    final outside = dx.abs() > _halfBox || dy.abs() > _halfBox;
    final onEntrySide = dy > _halfBox; // south approach
    return outside && !onEntrySide;
  }

  bool _playerViolationFired = false;
  bool _yieldLineCrossed = false;
  bool _clearedReported = false;

  void _checkPlayerYield(
    PlayerCar playerCar,
    List<_VehicleSample> samples,
  ) {
    final playerLocal = worldToLocal(playerCar.position);
    final localY = playerLocal.y;

    // Fresh approach — well south of the line.
    if (localY > _playerStopLineY + 60) {
      _playerViolationFired = false;
      _yieldLineCrossed = false;
      _clearedReported = false;
      return;
    }

    // Cleared the box via any exit (straight, left or right) — tell the
    // scenario once; a pass is positive feedback for the HUD.
    if (_playerExitedBox(playerLocal)) {
      if (!_clearedReported) {
        _clearedReported = true;
        scenario.onSafelyCleared();
        if (scenario.result.status == ScenarioStatus.passed) {
          GameBus.instance.emit(RulePassedEvent());
        }
      }
      return;
    }

    // The painted line is the yield decision point — evaluated once as the
    // player crosses it. It's a yield, not a mandatory stop: crossing fast is
    // only a violation when the right-of-way rules actually required the
    // player to give way at that moment.
    if (!_yieldLineCrossed && localY <= _playerStopLineY) {
      _yieldLineCrossed = true;
      scenario.onPlayerPassedYieldLine(playerCar.speed);

      final threatened = _mustGiveWay(
          Heading.north, playerPaths.first, maneuver, playerLocal, samples);
      if (threatened &&
          playerCar.speed > kYieldSpeedThreshold &&
          !_playerViolationFired) {
        _playerViolationFired = true;
        debugPrint('[INTERSECTION] yield violation @ stop line: '
            'speed=${playerCar.speed.toStringAsFixed(0)}');
        GameBus.instance
            .emit(YieldViolationEvent(speedAtLine: playerCar.speed));
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
    _drawRoundedCurbs(canvas);
    _drawRoads(canvas);
    _drawIntersectionBox(canvas);
    _drawMarkings(canvas);
    _drawStopLines(canvas);
    debugRenderSplines(canvas);
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kTileSize, kTileSize),
      Paint()..color = const Color(0xFF4CAF50),
    );
  }

  void _drawPavement(Canvas canvas) {
    final p = Paint()..color = const Color(0xFFBDBDBD);
    final roadL = _cx - kRoadWidth / 2 - kPavementWidth;
    final roadR = _cx + kRoadWidth / 2;
    canvas.drawRect(Rect.fromLTWH(roadL, 0, kPavementWidth, kTileSize), p);
    canvas.drawRect(Rect.fromLTWH(roadR, 0, kPavementWidth, kTileSize), p);

    final roadT = _cy - kRoadWidth / 2 - kPavementWidth;
    final roadB = _cy + kRoadWidth / 2;
    canvas.drawRect(Rect.fromLTWH(0, roadT, kTileSize, kPavementWidth), p);
    canvas.drawRect(Rect.fromLTWH(0, roadB, kTileSize, kPavementWidth), p);
  }

  void _drawRoads(Canvas canvas) {
    final p = Paint()..color = const Color(0xFF424242);
    canvas.drawRect(
      Rect.fromLTWH(_cx - kRoadWidth / 2, 0, kRoadWidth, kTileSize),
      p,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, _cy - kRoadWidth / 2, kTileSize, kRoadWidth),
      p,
    );
  }

  void _drawIntersectionBox(Canvas canvas) {
    canvas.drawRect(
      Rect.fromCenter(
        center: const Offset(_cx, _cy),
        width: kRoadWidth,
        height: kRoadWidth,
      ),
      Paint()..color = const Color(0xFF4E4E4E),
    );
  }

  /// Rounds the four sharp grass/pavement corners by overpainting the corner
  /// wedge with pavement, leaving a convex curb arc — like a real street corner.
  void _drawRoundedCurbs(Canvas canvas) {
    final p = Paint()..color = const Color(0xFFBDBDBD);
    final left = _cx - kRoadWidth / 2 - kPavementWidth; // outer pavement edges
    final right = _cx + kRoadWidth / 2 + kPavementWidth;
    final top = _cy - kRoadWidth / 2 - kPavementWidth;
    final bottom = _cy + kRoadWidth / 2 + kPavementWidth;

    _curbWedge(canvas, left, top, -1, -1, p); // top-left
    _curbWedge(canvas, right, top, 1, -1, p); // top-right
    _curbWedge(canvas, left, bottom, -1, 1, p); // bottom-left
    _curbWedge(canvas, right, bottom, 1, 1, p); // bottom-right
  }

  /// Fills the wedge between a sharp corner at ([cornerX], [cornerY]) and a
  /// quarter-circle arc of [_curbRadius], where ([sx], [sy]) point from the
  /// corner into the grass quadrant being rounded off.
  void _curbWedge(
      Canvas canvas, double cornerX, double cornerY, int sx, int sy, Paint p) {
    const r = _curbRadius;
    final center = Offset(cornerX + sx * r, cornerY + sy * r);
    final p1 = Offset(cornerX, cornerY + sy * r); // on the vertical curb
    final p2 = Offset(cornerX + sx * r, cornerY); // on the horizontal curb

    final a1 = math.atan2(p1.dy - center.dy, p1.dx - center.dx);
    final a2 = math.atan2(p2.dy - center.dy, p2.dx - center.dx);
    double sweep = a1 - a2;
    if (sweep > math.pi) sweep -= 2 * math.pi;
    if (sweep < -math.pi) sweep += 2 * math.pi;

    final path = Path()
      ..moveTo(p1.dx, p1.dy)
      ..lineTo(cornerX, cornerY)
      ..lineTo(p2.dx, p2.dy)
      ..arcTo(Rect.fromCircle(center: center, radius: r), a2, sweep, false)
      ..close();
    canvas.drawPath(path, p);
  }

  /// White stop lines just before the box on each of the four approaches,
  /// spanning the entering (right-hand) lane of that direction.
  void _drawStopLines(Canvas canvas) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.butt;
    const g = _stopLineGap;

    // N-bound (player) — south of box, east half.
    canvas.drawLine(Offset(_cx, _cy + _halfBox + g),
        Offset(_cx + _halfBox, _cy + _halfBox + g), p);
    // S-bound — north of box, west half.
    canvas.drawLine(Offset(_cx - _halfBox, _cy - _halfBox - g),
        Offset(_cx, _cy - _halfBox - g), p);
    // E-bound — west of box, south half.
    canvas.drawLine(Offset(_cx - _halfBox - g, _cy),
        Offset(_cx - _halfBox - g, _cy + _halfBox), p);
    // W-bound — east of box, north half.
    canvas.drawLine(Offset(_cx + _halfBox + g, _cy - _halfBox),
        Offset(_cx + _halfBox + g, _cy), p);
  }

  void _drawMarkings(Canvas canvas) {
    final center = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3;

    _drawDash(canvas, _cx, 0, _cx, _cy - _halfBox, center);
    _drawDash(canvas, _cx, _cy + _halfBox, _cx, kTileSize, center);
    _drawDash(canvas, 0, _cy, _cx - _halfBox, _cy, center);
    _drawDash(canvas, _cx + _halfBox, _cy, kTileSize, _cy, center);
  }

  void _drawDash(
      Canvas canvas, double x1, double y1, double x2, double y2, Paint p) {
    const dashLen = 40.0;
    const gapLen = 40.0;
    final pathLen = ((x2 - x1).abs() + (y2 - y1).abs());
    if (pathLen < 1) return;
    final horizontal = (x2 - x1).abs() > (y2 - y1).abs();
    double d = 0;
    while (d < pathLen) {
      final endD = (d + dashLen).clamp(0.0, pathLen);
      final start = horizontal ? Offset(x1 + d, y1) : Offset(x1, y1 + d);
      final end = horizontal ? Offset(x1 + endD, y1) : Offset(x1, y1 + endD);
      canvas.drawLine(start, end, p);
      d += dashLen + gapLen;
    }
  }
}

enum _Zone { far, approaching, inBox, past }

class _VehicleSample {
  _VehicleSample({
    required this.heading,
    required this.path,
    required this.localPos,
    required this.speed,
  });

  /// Travel heading on the approach.
  final Heading heading;

  /// Tile-local movement path — used for geometric conflict checks.
  final Spline path;

  final Vector2 localPos;
  final double speed;
}
