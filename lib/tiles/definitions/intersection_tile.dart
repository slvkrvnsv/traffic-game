import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../../core/constants.dart';
import '../../core/maneuver.dart';
import '../../core/spline.dart';
import '../../core/game_bus.dart';
import '../../cars/npc_car.dart';
import '../../cars/player_car.dart';
import '../../pedestrians/pedestrian.dart';
import '../../feedback/driver_reaction.dart';
import '../../feedback/driver_reaction_detector.dart' show DriverReactionDetector;
import '../../feedback/reaction_bubble.dart';
import '../environment.dart';
import '../../debug/debug_state.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../traffic_signal.dart';
import '../scenarios/scenario_base.dart';
import '../scenarios/scenario_registry.dart';
import '../scenarios/stop_sign_scenario.dart';
import '../scenarios/traffic_light_scenario.dart';

/// Cardinal heading of a vehicle travelling through the intersection.
/// Ordered clockwise so `(index + 1) % 4` = next clockwise neighbour.
enum Heading { north, east, south, west }

// [IntersectionControl] (all-way stop vs traffic light) lives in tile_registry —
// it's read here via the scenario the tile was dressed with (see [control]) and
// is pinnable in test mode through [TileSpawnContext.control].

/// 4-way US all-way STOP intersection.
///
/// In the canonical frame the player enters from the south; the commanded
/// [maneuver] decides whether the player path goes straight (exit north),
/// turns left (exit west) or right (exit east) — the corridor rotates
/// accordingly via tile placement. NPC traffic flows straight through in all
/// four cardinal directions.
///
/// A red STOP sign stands at every approach. The player must come to a
/// **complete stop** at the line, every time, even when the box is clear — a
/// rolling stop is a fault (graded by [StopSignScenario]). Right-of-way after
/// the stop is evaluated per *movement* (approach + path through the box): two
/// movements conflict when their paths actually cross or merge, computed
/// geometrically from the splines. On top of that: never enter an occupied
/// box, first-come-first-served, yield-to-the-right on ties, and a left turn
/// always gives way to oncoming traffic.
class IntersectionTile extends TileBase {
  IntersectionTile({
    this.maneuver = Maneuver.straight,
    super.tileType = TileType.intersection4way,
    super.locale,
    ScenarioBase? scenario,
  }) : super(scenario: scenario ?? StopSignScenario());

  /// The exam instruction for this tile.
  final Maneuver maneuver;

  @override
  Maneuver? get commandedManeuver => maneuver;

  /// Whether this intersection is an all-way stop or a traffic light — read off
  /// the scenario it was dressed with, so the control axis rides on the existing
  /// geometry × scenario seam (see [ScenarioRegistry]).
  IntersectionControl get control => scenario is TrafficLightScenario
      ? IntersectionControl.trafficLight
      : IntersectionControl.allWayStop;

  /// The signal cycle (traffic-light control only). Seeded from the tile's fixed
  /// world position so neighbouring lights aren't phase-locked and the start
  /// phase is deterministic. Lazily built (after [place], so the seed is stable)
  /// and ticked every frame in [update].
  late final TrafficSignalController _signal =
      TrafficSignalController(seed: position.x.round() + position.y.round() * 31);

  bool _isNorthSouth(Heading h) =>
      h == Heading.north || h == Heading.south;

  /// The phase the signal shows the given approach.
  SignalPhase _phaseOf(Heading h) =>
      _signal.phaseFor(northSouth: _isNorthSouth(h));

  @override
  void update(double dt) {
    super.update(dt); // ticks the scenario
    // Cycle the lights for every live signal tile (active and trailing), so the
    // signals a passed-but-still-visible tile carries keep changing.
    if (control == IntersectionControl.trafficLight) _signal.tick(dt);
  }

  static void register() {
    TileRegistry.register(
      TileType.intersection4way,
      (ctx) => IntersectionTile(
        maneuver: ctx.maneuver ??
            Maneuver.values[
                (ctx.rng ?? math.Random()).nextInt(Maneuver.values.length)],
        locale: ctx.locale,
        // Free-drive rolls the control via the registry; test mode can pin it
        // (ctx.control) so a given menu entry is reliably a stop or a light.
        scenario: switch (ctx.control) {
          IntersectionControl.allWayStop => StopSignScenario(),
          IntersectionControl.trafficLight => TrafficLightScenario(),
          null => ScenarioRegistry.forTile(TileType.intersection4way,
              rng: ctx.rng),
        },
      ),
      entryLanes: 1, // single-lane approach and exit each way
      exitLanes: 1,
      junction: true, // never chained back-to-back in free-drive
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

  /// Extra outward setback applied to the stop line ALONE (not the crossing) on
  /// urban junctions, so a car halted at the line sits a little further back from
  /// the zebra — more space between a waiting car and the crossing it's about to
  /// take. Urban only; interurban keeps its tight line.
  static const double _urbanStopLineExtra = 20.0;

  /// Painted stop line offset from the conflict-box edge (world units). Set so
  /// the line — and a car stopped behind it — sits clear of (outside) the zebra
  /// crossing, instead of a stopped car straddling it. The zebra band reaches
  /// _crosswalkOffset + _crosswalkHalf (=156 urban) from the tile centre; the
  /// line at _halfBox + _stopLineGap (=182 urban) sits beyond it, and a car halts
  /// ~a setback further back, so the whole car clears the band. Carries the
  /// crossing's [_crosswalkShift] (so the line tracks the crossing outward) PLUS
  /// an urban-only [_urbanStopLineExtra], so on urban junctions the line sits a
  /// little further beyond the zebra than the crossing alone would put it.
  /// Interurban keeps the original tight 44 (shift 0, no extra).
  double get _stopLineGap =>
      44.0 +
      _crosswalkShift +
      (locale == LocaleType.urban ? _urbanStopLineExtra : 0.0);

  /// Tile-local Y of the player's stop line on the south approach. Both the
  /// mandatory STOP and the fail-to-yield decision are judged here (the painted
  /// marking == the rule). In urban this line sits ~102u back from the conflict
  /// box, so a conflicting car already CROSSING the box is exempted from the
  /// yield check (see [_playerYieldTargets]) — it clears before a player at the
  /// line reaches the junction; only an approaching priority car counts.
  double get _playerStopLineY => _cy + _halfBox + _stopLineGap;

  /// How close to the stop line (along the approach) a complete stop must be
  /// made to count as stopping "at the sign" — ~1.5 car lengths. A full stop
  /// further back than this, followed by accelerating through the line, is a
  /// rolling stop, not a legal one.
  static const double _stopCreditWindow = kCarLength * 1.5;

  /// Radius of the rounded curb at each grass-side intersection corner (the
  /// pavement/grass corner, rounded off toward the tile corner).
  static const double _curbRadius = 72.0;

  /// Radius of the curb return at each inner corner — where a pavement corner
  /// pokes into the conflict box and turning traffic sweeps around it. Smaller
  /// than the grass-side [_curbRadius] (it lives inside the 40-wide pavement
  /// corner), just enough to take the sharp 90° off the curb the cars turn past.
  static const double _curbReturnRadius = 36.0;

  // ---------------------------------------------------------------------------
  // Pedestrian crossings (urban locale only)
  // ---------------------------------------------------------------------------

  /// Half-thickness of the zebra band.
  static const double _crosswalkHalf = 18.0;

  /// How far the urban crossing + stop line are pushed OUTWARD from the box,
  /// toward the approaching traffic, to open up a small junction. With the
  /// crossing right at the box edge the box reads cramped and a car that just
  /// cleared a zebra and stops is left with its tail on the stripes; pushing it
  /// out grows the box→crossing gap to ~40px (20px box→zebra-near-edge, plus the
  /// 18px band) so the junction breathes. The sidewalk centreline rides along
  /// with the crossing (a crossing is where a sidewalk meets a road), so this
  /// also carries the sidewalk ~18px past the 40px pavement's outer edge — an
  /// accepted trade for the more spacious box (the user chose the bigger push).
  ///
  /// LOWER BOUND: the pedestrian probe drops zebra direction-attribution, which
  /// is only safe while `_crosswalkOffset - kPedYieldLateral - _laneOffset >
  /// _zebraBandMargin` (asserted in [_pedStopOnPath]). Don't shrink this so far
  /// that a perpendicular crossing's band reaches the parallel lane, or
  /// corner-strollers will false-trip cars/the player.
  static const double _urbanCrosswalkShift = 38.0;

  /// The crossing + stop line are pushed this far OUTWARD from the box. Single
  /// knob — both move by it, and everything (detection bands, ped routes,
  /// frontages, the entry-commit gap, the painted markings) derives from the
  /// two offsets. URBAN ONLY: interurban junctions have no crossings, so they
  /// keep the original tight geometry (the user liked it) — the shift is 0 there.
  /// Tune urban spaciousness via [_urbanCrosswalkShift] alone.
  double get _crosswalkShift =>
      locale == LocaleType.urban ? _urbanCrosswalkShift : 0.0;

  /// Sidewalk centreline offset from the tile centre: the zebra bands sit here,
  /// and the pedestrian routes run along these lines, so a crossing is just where
  /// a sidewalk passes over a road. Pushed [_crosswalkShift] toward the building
  /// side of the pavement (from the pavement centre) so the crossing sits clear
  /// of the box (urban; interurban stays at the pavement centre, 100).
  double get _crosswalkOffset =>
      _halfBox + kPavementWidth * 0.5 + _crosswalkShift; // 138 urban / 100 rural
  double get _swLo => _cx - _crosswalkOffset; // 462 urban / 500 rural
  double get _swHi => _cx + _crosswalkOffset; // 738 urban / 700 rural

  static List<Vector2> _hLine(double y) => [
        Vector2(0, y),
        Vector2(kTileSize * 0.33, y),
        Vector2(kTileSize * 0.66, y),
        Vector2(kTileSize, y),
      ];
  static List<Vector2> _vLine(double x) => [
        Vector2(x, 0),
        Vector2(x, kTileSize * 0.33),
        Vector2(x, kTileSize * 0.66),
        Vector2(x, kTileSize),
      ];

  /// Pedestrian routes = the four full-length sidewalk centrelines, each
  /// direction. A walker spawns at a tile edge (off-screen as the tile streams
  /// in), strolls the sidewalk like a normal city pedestrian, crosses the one
  /// road its sidewalk passes over (at the zebra), and continues to the far
  /// edge — instead of popping onto the zebra and vanishing. Built lazily on
  /// first use (urban only); stable spline identity for the tile's lifetime.
  late final List<Spline> _crossingSplines = [
    for (final pts in [_hLine(_swLo), _hLine(_swHi), _vLine(_swLo), _vLine(_swHi)]) ...[
      Spline(pts),
      Spline(pts.reversed.toList()),
    ],
  ];

  @override
  List<Spline> get crossingPaths =>
      locale == LocaleType.urban ? _crossingSplines : const [];

  /// Grass corners outside the curb (corner edge at cx±(_halfBox+pavement)=480)
  /// — scattered with trees in the interurban locale.
  @override
  List<Rect> get decorationZones => const [
        Rect.fromLTWH(0, 0, 480, 480),
        Rect.fromLTWH(720, 0, kTileSize - 720, 480),
        Rect.fromLTWH(0, 720, 480, kTileSize - 720),
        Rect.fromLTWH(720, 720, kTileSize - 720, kTileSize - 720),
      ];

  /// Urban building blocks — one per corner, each fronting a different sidewalk
  /// (and so feeding a different zebra), sat on the outer side of that sidewalk.
  @override
  List<Frontage> get buildingFrontages => [
        // SE corner → south sidewalk (player's crossing).
        Frontage(
            a: Offset(760, _swHi),
            b: Offset(1160, _swHi),
            outward: Offset(0, 1)),
        // NW corner → north sidewalk.
        Frontage(
            a: Offset(40, _swLo), b: Offset(440, _swLo), outward: Offset(0, -1)),
        // SW corner → west sidewalk.
        Frontage(
            a: Offset(_swLo, 760),
            b: Offset(_swLo, 1160),
            outward: Offset(-1, 0)),
        // NE corner → east sidewalk.
        Frontage(
            a: Offset(_swHi, 40), b: Offset(_swHi, 440), outward: Offset(1, 0)),
      ];

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
  /// (lane index == approach heading index). Each lane offers its movements; the
  /// spawner picks one per car, so NPC traffic turns too.
  ///
  /// At a traffic light the LEFT turn is dropped: a permissive left would have to
  /// yield to oncoming traffic on the same green, and rather than arbitrate that
  /// (a later, protected-left pass) NPCs simply go straight or right through a
  /// signal — so a green box is always conflict-free. The all-way stop keeps all
  /// three movements (its ticketing arbitrates every conflict). The player is
  /// unaffected — it can still be commanded a left and must yield to oncoming.
  @override
  late final List<List<Spline>> npcLanes = [
    for (int k = 0; k < Heading.values.length; k++)
      [
        for (final m in Maneuver.values)
          if (!(control == IntersectionControl.trafficLight &&
              m == Maneuver.left))
            Spline([
              for (final p in _southApproachPoints(m)) _rotateQuarters(p, k),
            ]),
      ],
  ];

  @override
  late final List<Spline> npcPaths = [for (final lane in npcLanes) ...lane];

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

  /// Greedy first-come-first-served release for an all-way stop. Given the
  /// waiters in ascending arrival-ticket order, the ids already committed to
  /// the box ([going] — cars in the box plus earlier grants), and a [conflicts]
  /// predicate, returns the full set permitted to proceed.
  ///
  /// A waiter is released unless a *conflicting* car is already going. Walking
  /// in ticket order means the earliest of any mutually-conflicting group wins
  /// and the rest hold, so the result is a total order that cannot dead-lock:
  /// for any set of conflicting stopped cars at least one (the lowest ticket)
  /// proceeds, and the next proceeds once it clears. Pure and side-effect free
  /// so the invariant is unit-testable without splines or live cars.
  @visibleForTesting
  static Set<Object> computeReleases(
    List<Object> waitersByTicket,
    Set<Object> going,
    bool Function(Object a, Object b) conflicts,
  ) {
    final result = Set<Object>.from(going);
    for (final w in waitersByTicket) {
      final blocked = result.any((g) => g != w && conflicts(w, g));
      if (!blocked) result.add(w);
    }
    return result;
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

  /// Distance from [localPos] to the FAR edge of the conflict box along the
  /// travel axis (positive while still short of it; a vehicle has fully crossed
  /// once its body is past this). Drives the box-clearance ("don't block the
  /// box") check.
  double _gapToBoxFarEdge(Heading heading, Vector2 localPos) {
    switch (heading) {
      case Heading.north: // moving -y; far edge at y = cy - halfBox
        return localPos.y - (_cy - _halfBox);
      case Heading.south: // moving +y; far edge at y = cy + halfBox
        return (_cy + _halfBox) - localPos.y;
      case Heading.east: // moving +x; far edge at x = cx + halfBox
        return (_cx + _halfBox) - localPos.x;
      case Heading.west: // moving -x; far edge at x = cx - halfBox
        return localPos.x - (_cx - _halfBox);
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
    List<Pedestrian> pedestrians,
  ) {
    // lead-car gaps etc. Crossing-pedestrian yielding is handled in the apply
    // loop below: a car is HELD at its stop line while a pedestrian is on the
    // zebra ahead (it never stops on the crossing — once past the line it
    // commits and clears).
    super.updateNpcSensors(dt, playerCar, allNpcs, pedestrians);

    // Cache for the debug zebra-box overlay (rendered separately).
    if (kDebugMode && DebugState.showDebug) _debugPeds = pedestrians;

    // The pedestrian hold for every vehicle — the distance to the nearest
    // crossing pedestrian ahead on its OWN movement spline, or null if clear.
    // Computed ONCE here (the single probe) along each car's actual spline (the
    // known-correct pair: `spline` + its own `distanceTravelled`, matching what
    // the player wait/road-block exemption has always used), then reused for the
    // player wait flag, the pedestrian-aware arbitration, and the per-NPC apply
    // loop — so it's never walked twice.
    final playerSpline = playerCar.spline;
    final playerPedStop = playerSpline != null
        ? _pedStopOnPath(playerSpline, playerCar.distanceTravelled, pedestrians)
        : null;
    final pedStopById = <Object, double?>{
      _playerId: playerPedStop,
      for (final npc in npcs)
        if (npc.spline != null)
          npc: _pedStopOnPath(
              npc.spline!, npc.distanceTravelled, pedestrians),
    };

    // A crossing pedestrian is ahead in the player's path → a legitimate wait
    // (and what exempts the road-block penalty). Entry and exit (turn) crossings
    // are both covered by walking the player's own spline — no separate cone.
    _pedBlockingPlayer = playerPedStop != null;

    // Traffic-light control: the signal phase arbitrates the box, so the
    // all-way-stop ticketing below is bypassed entirely. Everything shared —
    // the pedestrian probe (above), the zone test, the stop-line geometry, the
    // player-approach state machine and the pedestrian give-way fault — is
    // reused; only the per-NPC apply, the player's at-line verdict and the
    // signage differ. (Left turns aren't offered to NPCs here — see [npcLanes].)
    if (control == IntersectionControl.trafficLight) {
      _applySignalToNpcs(pedStopById, allNpcs, playerCar);
      _signalPlayerWait(playerCar);
      _checkPlayerApproach(playerCar); // resets latches + red-light fault
      // Permissive left gives way to oncoming on the SAME green. Not checked on
      // yellow (oncoming is itself clearing) or red (the run-the-red fault
      // covers it) — a deliberate exemption, gated here not by accident.
      if (_phaseOf(Heading.north) == SignalPhase.green) {
        _checkLeftYieldToOncoming(playerCar, requireRightOfWay: false);
      }
      _checkPedestrianGiveWay(playerCar, pedestrians);
      _checkBlockedIntersection(dt, playerCar, allNpcs);
      return;
    }

    // Collect every vehicle that sits on one of *this* tile's lanes together
    // with its heading and identity, in tile-local coordinates.
    final samples = <_VehicleSample>[
      // Player always enters from the south in the canonical frame; its path
      // through the box depends on the commanded maneuver.
      _VehicleSample(
        id: _playerId,
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
            id: npc,
            heading: Heading.values[npc.laneIndex],
            path: npc.spline!,
            localPos: worldToLocal(npc.position),
            speed: npc.speed,
          ),
    ];
    // Vehicles that step OUT of the right-of-way contest while held at their own
    // line — the box stays free for cross traffic, they keep their ticket to
    // reclaim their turn, and the player isn't faulted for going around them.
    // Scoped to `approaching` + at/behind the line (a car stopped INSIDE the box
    // still blocks — it physically occupies the intersection). Two reasons, one
    // handling:
    //   * a pedestrian on their crossing ahead (`pedStop != null`), AND/OR
    //   * (anti-gridlock, "don't block the box") an NPC that can't fully clear
    //     the box — a stopped queue ahead leaves no room past the far edge — so
    //     it holds before entering instead of stalling in the intersection.
    // The player is never auto-held here; it earns the blocked-intersection
    // fault ([_checkBlockedIntersection]) if it gets stuck in the box itself.
    final yieldingAtEntry = <Object>{
      for (final v in samples)
        if (_zoneOf(v.heading, v.localPos) == _Zone.approaching &&
            _gapToStopLine(v.heading, v.localPos) >= 0 &&
            (pedStopById[v.id] != null ||
                (v.id is NpcCar &&
                    cannotClearBox(_gapToBoxFarEdge(v.heading, v.localPos),
                        _stoppedLeadGap(v.id as NpcCar, allNpcs, playerCar)))))
          v.id,
    };

    final going = _arbitrateAllWayStop(dt, samples, yieldingAtEntry);
    _playerReleased = going.contains(_playerId);

    // Apply the decision to each NPC. A car not yet released must stop at its
    // line (the mandatory all-way stop); a released car cruises through. A car
    // waiting on a hesitating player flashes its headlights (waving you on).
    for (final npc in npcs) {
      // Clear transient cues first, so a car that slips into an invalid state
      // (and skips the rest of the loop) never keeps a stale flash / speed cap.
      npc.setHeadlightFlash(_playerWaiters.contains(npc));
      if (npc.laneIndex < 0 ||
          npc.laneIndex >= Heading.values.length ||
          npc.spline == null) {
        npc.brain.speedCap = null;
        continue;
      }
      final heading = Heading.values[npc.laneIndex];
      final localPos = worldToLocal(npc.position);
      final z = _zoneOf(heading, localPos);

      // One mechanism for pedestrians: the distance to the nearest crossing
      // pedestrian ahead on this car's own path, or null if the way is clear.
      // Always evaluated — entry crossing, exit crossing, mid-turn, all the same
      // probe — and the brain brakes to it like any other stop-target. Computed
      // once above (also feeds `yieldingAtEntry`), looked up here.
      final pedStop = pedStopById[npc];

      if (z != _Zone.approaching) {
        // In the box or past the line — the all-way-stop hold is behind it; the
        // only thing left to stop for is a pedestrian on a crossing still ahead.
        npc.brain.intersectionRuleActive = false;
        npc.brain.hasRightOfWay = true;
        npc.brain.stopTargetDistance = pedStop;
        // Hold crossing speed while a zebra is still on the path ahead — not just
        // while `inBox`. A TURNING car reads `far` the moment it clears the box
        // (its approach-axis coordinate is past it), but its EXIT crosswalk sits
        // further out; without this the speed cap drops there and the car
        // accelerates across the crossing, sweeping close in front of a
        // pedestrian. A cap (not a stop) still clears the stripes — no freeze.
        final overCrossing =
            _crossingAhead(npc.spline!, npc.distanceTravelled, kCarLength * 2);
        npc.brain.speedCap =
            (z == _Zone.inBox || overCrossing) ? kNpcTurnSpeed : null;
        continue;
      }

      // Approaching the line. Hold at the line until the arbiter releases this
      // car (the all-way-stop turn order); a released car has no car-stop. The
      // pedestrian probe is layered on as a second stop-target and the brain
      // brakes to whichever is nearer — so a released car still stops short of a
      // busy crossing, and once its reference point is on the stripes the probe
      // skips that band (commit & clear), so it never freezes straddling them.
      final go = going.contains(npc);
      final carStop = go ? null : _gapToStopLine(heading, localPos);
      npc.brain.intersectionRuleActive = !go;
      npc.brain.hasRightOfWay = go;
      npc.brain.stopTargetDistance = _nearerStop(carStop, pedStop);
      // A released car eases out of the line at a calm crossing speed rather
      // than flooring it — especially when it's taking a hesitating player's turn.
      npc.brain.speedCap = go ? kNpcTurnSpeed : null;
    }

    // The player legitimately waits while approaching/inside the box until the
    // arbiter releases it — used to exempt that stop from the road-blocking
    // penalty. (The player isn't *forced* to stop here; the stop-sign fault is
    // graded separately in [_checkPlayerApproach].)
    final playerLocal = worldToLocal(playerCar.position);
    if (kDebugMode && DebugState.showDebug) _debugPlayerLocal = playerLocal;
    final pZone = _zoneOf(Heading.north, playerLocal);
    // Waiting your turn AT THE LINE (approaching) is always exempt from the
    // road-blocking penalty. Inside the box it's exempt ONLY while another car
    // is also in the box — i.e. a genuine yield (e.g. a left-turner waiting for
    // oncoming to clear). A player parked *alone* in the box is blocking the
    // intersection for cross-traffic that's stuck behind it (it's a blocker,
    // and the hesitation/demotion machinery only covers the approach), so it is
    // NOT exempt — letting that earn a road-block fault is the deadlock-breaker.
    // A normal crossing clears well within the road-block grace.
    _playerMustWait = pZone == _Zone.approaching ||
        (pZone == _Zone.inBox && _otherCarInBox) ||
        _pedBlockingPlayer; // waiting for someone on the crossing is rational

    // Player stop-sign / fail-to-yield detection (at-line verdict, all-way stop).
    _checkPlayerApproach(playerCar);
    // US rule 4 (straight-before-left on simultaneous arrival): a left-turning
    // player gives way to an oncoming straight car crossing with the right of
    // way. The at-line check exempts left-vs-oncoming (pulling into the box to
    // wait isn't a fault); this catches actually cutting it off mid-box.
    _checkLeftYieldToOncoming(playerCar, requireRightOfWay: true);

    // Pedestrian give-way fault — evaluated separately so it also covers the EXIT
    // crossings, which sit outside the box (where [_checkPlayerApproach] bails).
    _checkPedestrianGiveWay(playerCar, pedestrians);

    // "Don't block the box" — stuck inside the intersection behind a queue.
    _checkBlockedIntersection(dt, playerCar, allNpcs);
  }

  // ---------------------------------------------------------------------------
  // Traffic-light control — signal-phase arbitration (replaces ticketing)
  // ---------------------------------------------------------------------------

  /// The stop-target a signalised approach imposes on a vehicle [gapToLine] from
  /// its stop line (positive while still BEFORE the line, negative once AT or
  /// PAST it), folded with any [pedStop] still ahead.
  ///
  /// The commit-&-clear rule: green never stops for the light; on a non-green a
  /// car still before the line holds AT it, but a car at or past the line
  /// (`gapToLine <= 0`) gets NO light stop — it must clear the box, never freeze
  /// in the junction mouth when the light drops to yellow/red mid-crossing (a
  /// negative gap fed to the brain would brake it to a dead stop in the box).
  /// This is the signal's equivalent of the all-way stop's sticky `_granted`.
  /// Pure, so the seam is unit-testable without live cars.
  @visibleForTesting
  static double? signalStopTarget(
          bool green, double gapToLine, double? pedStop) =>
      _nearerStop((green || gapToLine <= 0) ? null : gapToLine, pedStop);

  /// Apply the signal phase to every NPC on this tile. Traffic with a green
  /// flows through at speed; traffic facing yellow or red holds at its stop line
  /// — the same kinematic brake the all-way-stop hold uses, folded together with
  /// the pedestrian probe via [_nearerStop]. A car already in the box commits and
  /// clears. NPC left turns aren't offered at a signal (see [npcLanes]), so a
  /// green box never has a permissive-left conflict to negotiate.
  void _applySignalToNpcs(Map<Object, double?> pedStopById,
      List<NpcCar> allNpcs, PlayerCar playerCar) {
    for (final npc in npcs) {
      npc.setHeadlightFlash(false); // no hesitation-wave at a signal
      if (npc.laneIndex < 0 ||
          npc.laneIndex >= Heading.values.length ||
          npc.spline == null) {
        npc.brain.intersectionRuleActive = false;
        npc.brain.hasRightOfWay = true;
        npc.brain.stopTargetDistance = null;
        npc.brain.speedCap = null;
        continue;
      }
      final heading = Heading.values[npc.laneIndex];
      final localPos = worldToLocal(npc.position);
      final z = _zoneOf(heading, localPos);
      final pedStop = pedStopById[npc];

      if (z != _Zone.approaching) {
        // In the box or past the line — committed; the only thing left to stop
        // for is a pedestrian on a crossing still ahead. Keep a calm crossing
        // speed only while a zebra is actually on the path ahead (a turn's exit
        // crosswalk, where [_zoneOf] already reads `far`); otherwise let
        // straight-through traffic clear the box at speed.
        npc.brain.intersectionRuleActive = false;
        npc.brain.hasRightOfWay = true;
        npc.brain.stopTargetDistance = pedStop;
        final overCrossing =
            _crossingAhead(npc.spline!, npc.distanceTravelled, kCarLength * 2);
        npc.brain.speedCap = overCrossing ? kNpcTurnSpeed : null;
        continue;
      }

      // Approaching: go on green, otherwise hold at the line. Green traffic is
      // NOT capped to crossing speed (unlike a car easing out of a dead stop) —
      // it flows through; a turning car is slowed onto its curve by the brain's
      // own curve-speed cap, so right-turners still take the corner calmly.
      final green = _phaseOf(heading) == SignalPhase.green;
      final gap = _gapToStopLine(heading, localPos);
      final committed = green || gap <= 0; // green, or already at/past the line
      // Don't block the box: even on green, hold at the line if there's no room
      // to fully clear (a stopped queue ahead) — anti-gridlock. Red already holds
      // via signalStopTarget, and cross traffic is red, so holding here stalls
      // no one. Only while still BEFORE the line (gap > 0); once in, commit & clear.
      final boxBlocked = green &&
          gap > 0 &&
          cannotClearBox(_gapToBoxFarEdge(heading, localPos),
              _stoppedLeadGap(npc, allNpcs, playerCar));
      final goNow = committed && !boxBlocked;
      npc.brain.intersectionRuleActive = !goNow;
      npc.brain.hasRightOfWay = goNow;
      npc.brain.stopTargetDistance = _nearerStop(
          signalStopTarget(green, gap, pedStop), boxBlocked ? gap : null);
      npc.brain.speedCap = null;
    }
  }

  /// Mark the player's standstill at a signal as a *rational* wait (exempt from
  /// the road-blocking penalty) when it is one: held at a red, yielding to a car
  /// already in the box, waiting on a pedestrian, or — on a commanded left —
  /// giving way to oncoming traffic on a permissive green. Oncoming runs in the
  /// opposite lane, so the road-block detector's in-lane forward scan can't see
  /// it; this flag is the only lever, mirroring the all-way-stop in-box yield.
  /// Sitting still on a green with a clear box and no oncoming is NOT exempt.
  void _signalPlayerWait(PlayerCar playerCar) {
    final playerLocal = worldToLocal(playerCar.position);
    if (kDebugMode && DebugState.showDebug) _debugPlayerLocal = playerLocal;
    final pZone = _zoneOf(Heading.north, playerLocal);
    final green = _phaseOf(Heading.north) == SignalPhase.green;

    _otherCarInBox = npcs.any((n) =>
        n.laneIndex >= 0 &&
        n.laneIndex < Heading.values.length &&
        n.spline != null &&
        _zoneOf(Heading.values[n.laneIndex], worldToLocal(n.position)) ==
            _Zone.inBox);

    // A permissive LEFT gives way to oncoming (the south approach, as the
    // all-way-stop fail-to-yield exemption also encodes). Waiting for a gap is
    // rational while an oncoming car is approaching or in the box.
    final oncomingPresent = maneuver == Maneuver.left &&
        npcs.any((n) {
          if (n.laneIndex != Heading.south.index || n.spline == null) {
            return false;
          }
          final z = _zoneOf(Heading.south, worldToLocal(n.position));
          return z == _Zone.approaching || z == _Zone.inBox;
        });

    _playerMustWait = (pZone == _Zone.approaching && !green) ||
        (pZone == _Zone.inBox && _otherCarInBox) ||
        ((pZone == _Zone.approaching || pZone == _Zone.inBox) &&
            oncomingPresent) ||
        _pedBlockingPlayer;
  }

  /// Fail-to-yield on a LEFT turn across oncoming through-traffic (the south
  /// approach going straight) — shared by both controls. Fires when the *moving*
  /// player pulls across in front of an oncoming STRAIGHT car close/fast enough
  /// to be forced into a hard brake ([leftTurnCutsOffOncoming]) — it didn't wait
  /// for a safe gap. Waiting in the box (stopped) is never a fault (and is
  /// road-block-exempt — see [_signalPlayerWait]); turning into a clear gap is
  /// fine (a far/slow car isn't cut off); an actual collision is still the only
  /// game-over. One fault per approach (shares the [_yieldViolationFired] latch,
  /// reset far-south in [_checkPlayerApproach]).
  ///
  /// [requireRightOfWay] is the per-control difference:
  ///   * LIGHT (false): any oncoming on the same green has priority over a
  ///     permissive left — green traffic is flowing by definition.
  ///   * all-way STOP (true): only a car actually crossing with the right of way
  ///     (granted, or already in the box) counts — US rule 4 (straight-before
  ///     -left on simultaneous arrival). In practice that's the oncoming car the
  ///     arbiter released: a non-priority car is stopped at its line, too slow
  ///     to be "cut off" anyway, so this gate just makes the rule explicit.
  void _checkLeftYieldToOncoming(PlayerCar playerCar,
      {required bool requireRightOfWay}) {
    if (maneuver != Maneuver.left || _yieldViolationFired) return;
    if (playerCar.speed <= kStopSpeedThreshold) return; // waiting isn't a fault

    for (final npc in npcs) {
      if (npc.laneIndex != Heading.south.index || npc.spline == null) continue;
      if (!_movementStraight(npc.spline!)) continue; // oncoming THROUGH-traffic
      final z = _zoneOf(Heading.south, worldToLocal(npc.position));
      if (z != _Zone.approaching && z != _Zone.inBox) continue;
      if (requireRightOfWay && !(_granted.contains(npc) || z == _Zone.inBox)) {
        continue; // the oncoming car must actually hold the right of way
      }
      final gap = _oncomingGapToPlayer(npc, playerCar);
      if (gap == null) continue; // player not ahead in the oncoming lane (yet)
      if (!leftTurnCutsOffOncoming(npc.speed, gap)) continue;

      _yieldViolationFired = true;
      debugPrint('[INTERSECTION] left-turn fail-to-yield: oncoming '
          'speed=${npc.speed.toStringAsFixed(0)} gap=${gap.toStringAsFixed(0)}');
      GameBus.instance.emit(YieldViolationEvent(speedAtLine: playerCar.speed));
      _playerYieldTargets
        ..clear()
        ..add(npc);
      _markYieldTargets(playerCar); // red "!" on the car you cut off
      return;
    }
  }

  /// Bumper gap from oncoming [npc] to the player when the player is ahead in the
  /// NPC's lane (mirrors the lead-car geometry), else null — the player isn't in
  /// front of this oncoming car (so it can't be cut off by it).
  double? _oncomingGapToPlayer(NpcCar npc, PlayerCar playerCar) {
    final fwd = Vector2(math.cos(npc.angle), math.sin(npc.angle));
    final delta = playerCar.position - npc.position;
    final ahead = delta.dot(fwd);
    if (ahead < kCarLength * 0.5) return null; // behind / overlapping
    final lateral = (delta - fwd * ahead).length;
    if (lateral > kCarWidth * 1.8) return null; // different lane
    return (ahead - kCarLength).clamp(0.0, double.infinity);
  }

  /// Whether the player's left turn cuts off an oncoming car: it is moving with
  /// real speed and the [gapToPlayer] forces it to brake harder than ordinary
  /// following ever needs (the same forced-hard-brake test the cut-off detector
  /// uses, single-sourced so the threshold stays consistent). A far/slow car is
  /// NOT cut off — turning into a genuine gap is legal. Pure → unit-tested. To
  /// make the fault fire more eagerly, this is the seam for a left-turn-specific
  /// multiplier (currently shares the cut-off [kReactHardBrakeMultiplier]).
  @visibleForTesting
  static bool leftTurnCutsOffOncoming(double oncomingSpeed, double gapToPlayer) {
    if (oncomingSpeed < kReactMinSpeed) return false;
    return DriverReactionDetector.isForcedHardBrake(oncomingSpeed, gapToPlayer);
  }

  // ---------------------------------------------------------------------------
  // "Don't block the box" — stuck inside the intersection (gridlock)
  // ---------------------------------------------------------------------------

  /// Seconds the player must sit stuck in the box before it's a fault — a short
  /// grace so a momentary pause mid-crossing isn't punished.
  static const double _blockBoxGraceSeconds = 1.5;

  double _blockedBoxTimer = 0.0;
  bool _blockedBoxFired = false;

  /// True when the player's BODY overlaps the conflict box — sampled at nose,
  /// centre and tail (like [_playerOnBand]) so a PARTIAL overlap ("not fully in
  /// it") counts, deliberately separate from the centre-based [_zoneOf] the
  /// arbitration is tuned on (left untouched).
  bool _playerOverlapsBox(PlayerCar playerCar) {
    final fwd = Vector2(math.cos(playerCar.angle), math.sin(playerCar.angle));
    for (final s in const [kCarLength / 2, 0.0, -kCarLength / 2]) {
      final p = worldToLocal(playerCar.position + fwd * s);
      if ((p.x - _cx).abs() <= _halfBox && (p.y - _cy).abs() <= _halfBox) {
        return true;
      }
    }
    return false;
  }

  /// Whether a stuck car sits right ahead of the player in its lane — so the
  /// player can't move forward (it's blocked, not yielding). Kept TIGHT — a
  /// stopped car within ~2 lengths directly ahead — so it stays disjoint from
  /// the road-block check (which fires only when the forward path is CLEAR for
  /// [kClearPathAheadDistance]). A pedestrian on the exit is NOT counted here
  /// (that's the give-way fault's job — don't double-punish).
  bool _playerExitBlocked(PlayerCar playerCar, List<NpcCar> allNpcs) {
    final fwd = Vector2(math.cos(playerCar.angle), math.sin(playerCar.angle));
    for (final npc in allNpcs) {
      if (npc.speed > kStopSpeedThreshold) continue; // a moving car isn't a block
      final delta = npc.position - playerCar.position;
      final ahead = delta.dot(fwd);
      if (ahead <= 0 || ahead > kCarLength * 2.0) continue; // not right ahead
      final lateral = (delta - fwd * ahead).length;
      if (lateral > kCarWidth * 1.5) continue; // different lane
      return true;
    }
    return false;
  }

  /// "Don't block the box": fault the player for sitting STUCK in the
  /// intersection — body overlapping the conflict box, stopped, and a stuck car
  /// right ahead so it can't clear (obstructing cross traffic, NOT a legitimate
  /// in-box yield, whose exit is clear). A short grace avoids faulting a
  /// momentary pause; fired once per stuck episode, re-armed the moment the
  /// player frees up. Control-agnostic (a general intersection rule).
  void _checkBlockedIntersection(
      double dt, PlayerCar playerCar, List<NpcCar> allNpcs) {
    final stuck = playerCar.speed <= kStopSpeedThreshold &&
        _playerOverlapsBox(playerCar) &&
        _playerExitBlocked(playerCar, allNpcs);
    if (!stuck) {
      _blockedBoxTimer = 0.0;
      _blockedBoxFired = false;
      return;
    }
    _blockedBoxTimer += dt;
    if (_blockedBoxTimer >= _blockBoxGraceSeconds && !_blockedBoxFired) {
      _blockedBoxFired = true;
      debugPrint('[INTERSECTION] blocked the intersection (stuck in the box)');
      GameBus.instance.emit(BlockedIntersectionEvent());
    }
  }

  /// Whether a vehicle [gapToFarEdge] along its path short of the box's far edge
  /// CANNOT fully clear it, given the nearest STOPPED car [stoppedLeadGap] ahead
  /// (bumper-to-bumper; null = none). It clears only if that car leaves room for
  /// its whole body plus a standing gap beyond the far edge — otherwise entering
  /// would leave it stuck in the box. Pure → the "don't enter unless you can
  /// clear it" arithmetic is unit-tested.
  @visibleForTesting
  static bool cannotClearBox(double gapToFarEdge, double? stoppedLeadGap) {
    if (stoppedLeadGap == null || gapToFarEdge <= 0) return false;
    return stoppedLeadGap < gapToFarEdge + kCarLength + kNpcStandingGap;
  }

  /// Bumper gap to the nearest STOPPED vehicle ahead of [npc] in its lane (an
  /// NPC or the player), or null when the way ahead is clear of stopped cars.
  /// Only stopped cars count — a moving lead means traffic is flowing, so the
  /// gap re-opens as it advances and entering the box is fine.
  double? _stoppedLeadGap(
      NpcCar npc, List<NpcCar> allNpcs, PlayerCar playerCar) {
    final fwd = Vector2(math.cos(npc.angle), math.sin(npc.angle));
    double? best;
    void consider(Vector2 pos, double speed) {
      if (speed > kStopSpeedThreshold) return; // only a stopped car blocks
      final delta = pos - npc.position;
      final ahead = delta.dot(fwd);
      if (ahead < kCarLength * 0.5) return; // behind / overlapping
      final lateral = (delta - fwd * ahead).length;
      if (lateral > kCarWidth * 1.8) return; // different lane
      final gap = (ahead - kCarLength).clamp(0.0, double.infinity);
      if (best == null || gap < best!) best = gap;
    }

    for (final o in allNpcs) {
      if (!identical(o, npc)) consider(o.position, o.speed);
    }
    consider(playerCar.position, playerCar.speed);
    return best;
  }

  /// Whether a crossing pedestrian stepping onto zebra [band] (−1 = none) must
  /// hold at the curb for the signal. Pure — the two failure-prone bits are
  /// unit-tested directly:
  ///   * the band→road→phase map (an inversion sends peds in front of moving
  ///     traffic): bands 0 (south) & 1 (north) cross the **N–S** road; 2 (west)
  ///     & 3 (east) cross the **E–W** road. A ped may step off the curb only
  ///     once the road it crosses is RED (cars stopped) — exactly the parallel
  ///     -green walk phase.
  ///   * **commit & clear**: [alongFromCentre] is the ped's position along its
  ///     crossing axis relative to the tile centre, [travelSign] the sign of its
  ///     travel along that axis. Once it has reached the near carriageway edge
  ///     in its direction of travel (`alongFromCentre·travelSign >= −_halfBox`)
  ///     it is committed and is NEVER re-held — so a ped that entered on a walk
  ///     finishes crossing when the light changes, instead of freezing at the
  ///     far edge of the zebra band (the enter-margin it passes through on the
  ///     way out used to read as "approaching" again).
  @visibleForTesting
  static bool pedMustHoldForSignal(int band, double alongFromCentre,
      double travelSign, SignalPhase nsPhase, SignalPhase ewPhase) {
    if (band < 0) return false; // next step isn't onto a crossing
    final committed = alongFromCentre * travelSign >= -_halfBox;
    if (committed) return false; // on/past the near edge → finish crossing
    final crossesNS = band == 0 || band == 1;
    final crossedRoad = crossesNS ? nsPhase : ewPhase;
    return crossedRoad != SignalPhase.red; // hold while the crossed road moves
  }

  @override
  bool pedestrianHeldBySignal(Vector2 worldPos, Vector2 worldDir) {
    if (control != IntersectionControl.trafficLight) return false;
    // Probe in the tile-LOCAL frame — intersections placed downstream of a turn
    // are rotated, so a raw world probe would gate the wrong crossing.
    final local = worldToLocal(worldPos);
    final localDir = directionToLocal(worldDir);
    final band = _zebraIndexOf(local + localDir * kPedStepProbe); // next step
    if (band < 0) return false;
    final crossesNS = band == 0 || band == 1; // which road this crossing spans
    final along = crossesNS ? local.x - _cx : local.y - _cy;
    final sign = (crossesNS ? localDir.x : localDir.y).sign;
    return pedMustHoldForSignal(
        band, along, sign, _phaseOf(Heading.north), _phaseOf(Heading.east));
  }

  /// Sentinel identity for the player in the arrival-order bookkeeping.
  static final Object _playerId = Object();

  /// Arrival-order ("first to stop, first to go") tickets, keyed by vehicle
  /// identity, and the monotonic sequence that assigns them. A vehicle joins
  /// the queue the first frame it is at rest and frontmost on its approach.
  final Map<Object, int> _ticket = {};
  int _ticketSeq = 0;

  /// Vehicles already released to proceed; sticky so a car that has been waved
  /// through isn't re-stopped mid-crossing. Cleared when it leaves the tile or
  /// clears the box.
  final Set<Object> _granted = {};

  /// A car in the box that has driven past its conflict point (the box centre,
  /// plus a small margin) is on its way out, so it no longer blocks a
  /// conflicting car from starting — the next driver can roll as it clears.
  static const double _boxClearMargin = 8.0;

  /// Whether a car in the box has cleared the conflict region enough to stop
  /// blocking a conflicting waiter. For a **straight-through** car this is just
  /// "past the box centre along its travel axis" (its conflict point is the
  /// centre). A **turning** car is NOT judged by the approach axis — its body
  /// swings laterally across the box well after its approach-axis coordinate
  /// passes centre, so it must stay a blocker until it has fully left the box
  /// (zone `past`/`far`); otherwise a conflicting car is released into the box
  /// while the turner is still crossing it.
  bool _isClearing(Heading heading, Vector2 localPos, Spline path) =>
      _movementStraight(path) && _pastBoxCentre(heading, localPos);

  bool _pastBoxCentre(Heading heading, Vector2 localPos) {
    switch (heading) {
      case Heading.north: // moving -y
        return localPos.y < _cy - _boxClearMargin;
      case Heading.south: // moving +y
        return localPos.y > _cy + _boxClearMargin;
      case Heading.east: // moving +x
        return localPos.x > _cx + _boxClearMargin;
      case Heading.west: // moving -x
        return localPos.x < _cx - _boxClearMargin;
    }
  }

  /// Whether a movement runs straight through (entry direction ≈ exit
  /// direction). Cached per spline — path identity is stable for a tile.
  final Map<Spline, bool> _straightCache = {};
  bool _movementStraight(Spline path) => _straightCache.putIfAbsent(
      path, () => path.tangent(0.0).dot(path.tangent(1.0)) > 0.85);

  /// An NPC only flashes once it has itself come to a stop and waited at least
  /// this long — no flashing while still rolling up to the line.
  static const double _npcFlashAfterStopSeconds = 1.0;

  /// After the player has held the right of way but sat still this long, the
  /// waiting NPCs stop waiting and take the turn themselves, so a hesitating
  /// player can never freeze the intersection.
  static const double _hesitationGoSeconds = 3.0;

  /// How long the player has held the right of way without moving.
  double _playerHesitationTimer = 0.0;

  /// Sticky: the player forfeited its turn (hesitated past the go threshold).
  /// Stays set for the rest of the approach so a momentary twitch can't undo it.
  bool _playerDemoted = false;

  /// Whether a vehicle other than the player is currently inside the conflict
  /// box — used to tell a legitimate in-box yield (waiting for crossing traffic)
  /// from a player stalled alone in the intersection.
  bool _otherCarInBox = false;

  /// Per-NPC time spent stopped and waiting at the line (gates the flash).
  final Map<Object, double> _npcWaitTime = {};

  /// The single NPC flashing its headlights at the hesitating player (the one
  /// next in line). Held as a list so the apply loop's `.contains` check is
  /// uniform, but it carries at most one car.
  final List<NpcCar> _playerWaiters = [];

  /// True when a vehicle is yielding to a pedestrian at its entry: it is
  /// [atOwnLine] (approaching AND still at/behind its own stop line) and has a
  /// non-null pedestrian hold [pedStop] on its path. For such a car the nearest
  /// crossing the probe can return is its entry crossing, so it will not enter
  /// the box this turn — it is yielding, not taking its turn. Two exclusions
  /// matter: a car already IN the box keeps blocking (it occupies the
  /// intersection), and a car that has rolled PAST its line is committed — it
  /// keeps its turn and merely brakes for the pedestrian, rather than handing the
  /// box to cross traffic from the intersection mouth. Both are [atOwnLine] ==
  /// false. Pure, for unit-testing the scope.
  @visibleForTesting
  static bool isPedYieldingAtEntry(bool atOwnLine, double? pedStop) =>
      atOwnLine && pedStop != null;

  /// Run one frame of all-way-stop arbitration over [samples]; returns the ids
  /// committed to proceed (blocking the box, or released this frame).
  ///
  /// [yieldingAtEntry] are vehicles held at their own line — for a pedestrian on
  /// their crossing, or because they can't clear the box (anti-gridlock). They
  /// step out of the right-of-way contest while held: they don't block
  /// conflicting cross traffic, aren't released themselves, and don't outrank the
  /// player — but keep their arrival ticket, so each reclaims its turn once the
  /// hold clears.
  Set<Object> _arbitrateAllWayStop(
      double dt, List<_VehicleSample> samples, Set<Object> yieldingAtEntry) {
    final present = {for (final v in samples) v.id};
    _ticket.removeWhere((id, _) => !present.contains(id));
    _granted.removeWhere((id) => !present.contains(id));

    final zone = {for (final v in samples) v.id: _zoneOf(v.heading, v.localPos)};
    final gap = {
      for (final v in samples) v.id: _gapToStopLine(v.heading, v.localPos)
    };
    _otherCarInBox = samples
        .any((v) => v.id != _playerId && zone[v.id] == _Zone.inBox);

    // Hesitation: the player has been released (its turn) but is sitting still
    // at the line. Time it; past the flash threshold the waiters wave it on,
    // and past the go threshold the player is demoted so they take their turn.
    final playerSpeed =
        samples.firstWhere((v) => v.id == _playerId).speed;
    final playerHesitating = _granted.contains(_playerId) &&
        zone[_playerId] == _Zone.approaching &&
        playerSpeed <= kStopSpeedThreshold;
    _playerHesitationTimer = playerHesitating ? _playerHesitationTimer + dt : 0.0;
    // Demotion is *sticky* for the rest of this approach: once we've waved the
    // player on and the NPCs have started their turn, a one-frame twitch above
    // the stop threshold (which resets the timer) must not un-demote and let the
    // player's early ticket re-block the cars mid-pull-out. Cleared on the
    // fresh-approach reset in [_checkPlayerApproach].
    if (_playerHesitationTimer >= _hesitationGoSeconds) _playerDemoted = true;
    final demotePlayer = _playerDemoted;
    // Graceful handoff: once we've waved the player on and let the NPCs take
    // their turn, the player isn't penalised for finally going — suppress its
    // own fail-to-yield for this crossing (re-armed on the next approach).
    if (demotePlayer) _yieldViolationFired = true;

    // A car that has left the box is done — forget its ticket/grant. This must
    // cover both exits: straight out (`past`) AND turned away to the side, which
    // `_zoneOf` (measuring along the approach axis) reports as `far`. Clearing
    // only `past` left a turned car holding a stale ticket, so it kept
    // "outranking" the player long after it was gone — a phantom "failed to
    // yield to a car far away" on the next crossing. A car that simply hasn't
    // arrived yet is also `far` but holds no ticket, so this is safe.
    for (final v in samples) {
      final z = zone[v.id];
      if (z != _Zone.approaching && z != _Zone.inBox) {
        _ticket.remove(v.id);
        _granted.remove(v.id);
      }
    }

    // A car now yielding to a pedestrian at its line forfeits any release it
    // held — but KEEPS its ticket. This is what makes the hand-off race-free:
    // instead of resuming the instant the pedestrian clears (and driving into a
    // car that has since been released into the box), it re-enters as a normal
    // waiter and is blocked by whatever is now crossing, then released once that
    // clears. Its retained ticket keeps its place in line.
    _granted.removeWhere(yieldingAtEntry.contains);

    // Ticketing: a car claims its turn (arrival order) once it is at rest *and*
    // frontmost on its own approach — no other car ahead of it that is still
    // approaching the box. This is the all-way-stop "one car at a time" rule: a
    // queued follower can't take a ticket while the car ahead is still at/near
    // the line. Crucially the leader is NOT excluded just because it's been
    // released — only once it has *moved into the box* (zone != approaching)
    // does the follower become frontmost, pull up to the line, stop, and claim
    // its (now later) turn. So a cross car that stopped earlier always goes
    // before the follower, instead of the whole lane streaming through behind
    // the leader. No magic gap constant.
    for (final v in samples) {
      if (zone[v.id] != _Zone.approaching) continue;
      if (_ticket.containsKey(v.id) || _granted.contains(v.id)) continue;
      if (v.speed > kStopSpeedThreshold) continue;
      final frontmost = !samples.any((o) =>
          o.id != v.id &&
          o.heading == v.heading &&
          zone[o.id] == _Zone.approaching &&
          gap[o.id]! < gap[v.id]!);
      if (frontmost) {
        final n = _ticketSeq++;
        _ticket[v.id] = n;
        if (kDebugMode && DebugState.showDebug) {
          final who = v.id is NpcCar
              ? 'NPC L${(v.id as NpcCar).laneIndex}'
              : 'PLAYER';
          debugPrint('[INTERSECTION] turn #$n → $who '
              '(assigned on approach, at the line)');
        }
      }
    }

    // Cars that still block a conflicting waiter from starting: those committed
    // to the box and not yet clear of the conflict point — a released car still
    // heading in, or one in the box that hasn't passed the centre yet. A car
    // that's past the centre is on its way out (so the next driver rolls as it
    // clears, like real all-way-stop flow), and a car already *past* the box is
    // no threat at all. (The old code kept an exited car blocking for its whole
    // post-box traverse of the tile, so cross traffic waited far too long —
    // sometimes until the waiting car was culled.)
    final blockers = <Object>{
      for (final v in samples)
        // A player that has hesitated past the go threshold is demoted: it no
        // longer blocks, so the cars waiting on it take their turn. A car
        // yielding to a pedestrian at its line (approaching) doesn't block
        // either — the box is free behind it, so cross traffic flows.
        if (!(v.id == _playerId && demotePlayer) &&
            !yieldingAtEntry.contains(v.id) &&
            ((zone[v.id] == _Zone.approaching && _granted.contains(v.id)) ||
                (zone[v.id] == _Zone.inBox &&
                    !_isClearing(v.heading, v.localPos, v.path))))
          v.id,
    };

    // Eligible waiters: approaching, ticketed (i.e. have stopped), not already
    // committed — released greedily in arrival order, never into a conflict.
    final waiters = samples
        .map((v) => v.id)
        .where((id) =>
            zone[id] == _Zone.approaching &&
            _ticket.containsKey(id) &&
            !blockers.contains(id) &&
            // A car yielding to a pedestrian at its line isn't released — it's
            // holding for the crossing, not taking its turn (it keeps its ticket
            // and reclaims its turn once the pedestrian clears).
            !yieldingAtEntry.contains(id) &&
            // A demoted (hesitating) player forfeits its turn — it must not
            // re-win the release with its early ticket and re-block the NPCs.
            !(id == _playerId && demotePlayer))
        .toList()
      ..sort((a, b) => _ticket[a]!.compareTo(_ticket[b]!));

    final pathById = {for (final v in samples) v.id: v};
    final released = computeReleases(waiters, blockers, (a, b) {
      final va = pathById[a]!, vb = pathById[b]!;
      return _movementsConflict(va.heading, va.path, vb.heading, vb.path);
    });
    _granted.addAll(released.where((id) => zone[id] == _Zone.approaching));

    // Per-NPC stopped-wait timer: count up only while a car is stopped at its
    // line waiting (not while rolling up, not once released).
    final stillWaiting = <Object>{};
    for (final v in samples) {
      if (v.id is! NpcCar) continue;
      if (zone[v.id] == _Zone.approaching &&
          !released.contains(v.id) &&
          v.speed <= kStopSpeedThreshold) {
        _npcWaitTime[v.id] = (_npcWaitTime[v.id] ?? 0.0) + dt;
        stillWaiting.add(v.id);
      }
    }
    _npcWaitTime.removeWhere((id, _) => !stillWaiting.contains(id));

    // Headlight flash: while the player holds the right of way but sits still,
    // ONE car waves it on — the single conflicting NPC next in line (earliest
    // ticket), not the whole lane. And only when the box is physically clear
    // (`!_otherCarInBox`), so a car is never waved into a still-busy
    // intersection. The waiter must have itself stopped and waited a beat. (At
    // the go threshold the player is demoted above, the NPCs are released, and
    // the flashing naturally stops as they pull away.)
    _playerWaiters.clear();
    if (playerHesitating && !_otherCarInBox) {
      final p = pathById[_playerId]!;
      NpcCar? next;
      int nextTicket = 1 << 30;
      for (final v in samples) {
        if (v.id is! NpcCar) continue;
        if ((_npcWaitTime[v.id] ?? 0.0) < _npcFlashAfterStopSeconds) continue;
        if (zone[v.id] != _Zone.approaching || released.contains(v.id)) continue;
        // A car frozen for a pedestrian won't move, so it can't wave anyone on.
        if (yieldingAtEntry.contains(v.id)) continue;
        if (!_movementsConflict(p.heading, p.path, v.heading, v.path)) continue;
        final t = _ticket[v.id] ?? (1 << 30);
        if (t < nextTicket) {
          nextTicket = t;
          next = v.id as NpcCar;
        }
      }
      if (next != null) _playerWaiters.add(next);
    }

    // Which conflicting vehicles currently outrank the player? — those already
    // crossing/released, or that stopped before the player did. If any exist
    // the player must give way; crossing the line anyway is a fail-to-yield,
    // and these are the drivers who get the red "!" marker.
    final player = pathById[_playerId]!;
    final pTicket = _ticket[_playerId];
    _playerYieldTargets.clear();
    for (final o in samples) {
      if (o.id == _playerId) continue;
      if (!_movementsConflict(player.heading, player.path, o.heading, o.path)) {
        continue;
      }
      // A car stopped at its line for a pedestrian isn't exercising priority
      // over the player — it's yielding to the crossing. Going around it is not
      // a fail-to-yield-to-car (the player can still earn the separate
      // pedestrian give-way fault if it cuts off the ped).
      if (yieldingAtEntry.contains(o.id)) continue;
      // A left-turning player may pull into the box and yield to oncoming
      // traffic (the opposite approach, Heading.south) from within — entering
      // isn't a fault. So oncoming cars (whether going straight or turning
      // right into the same exit) don't trigger a fail-to-yield on a left turn;
      // only actually colliding does. Cross-traffic still counts.
      if (maneuver == Maneuver.left && o.heading == Heading.south) continue;
      // A conflicting car past the box centre, or gone, is on its way out —
      // pulling out behind it as it clears is normal, not a fail-to-yield (the
      // lenient past-centre test, not the strict straight-only `_isClearing`, so
      // a turner that's nearly out also stops counting). URBAN ONLY, also exempt
      // a car that's merely still MOVING through the box: there the stop line is
      // pushed ~102u back (see [_stopLineGap]), so a crossing car clears before a
      // player at the line can reach the junction. On INTERURBAN the line sits
      // ~44u back with no push-back, so a moving but not-yet-past-centre car can
      // still be in the player's path on arrival — keep the strict test there,
      // else a real T-bone goes unflagged. (Residual: a car crawling just above
      // kStopSpeedThreshold in urban may not actually clear; the deeper fix is to
      // reason about time-to-conflict rather than sample at a line far from the
      // box. What's left counting: an APPROACHING priority car — the real
      // queue-jump — or a car stopped/blocking IN the box.)
      final oz = zone[o.id];
      final clearingInBox = oz == _Zone.inBox &&
          ((locale == LocaleType.urban && o.speed > kStopSpeedThreshold) ||
              _pastBoxCentre(o.heading, o.localPos));
      if (oz == _Zone.past || clearingInBox) {
        continue;
      }
      final ot = _ticket[o.id];
      // Outranks the player if it's actively committed to the box (crossing /
      // released), or — only when the player has itself taken a turn ticket — it
      // took an earlier one. A player with NO ticket (never stopped) is NOT
      // flagged by a merely-waiting car: that's the player's own stop fault, and
      // flagging it too would spray "!" bubbles from every stopped cross-car on
      // a rolling player — the over-sensitive penalty the user rejected. (A
      // review finder flagged the narrow "rightful car blocked by a third car,
      // player never stopped" under-report; kept suppressed on purpose.)
      final outranks = released.contains(o.id) ||
          (pTicket != null && ot != null && ot < pTicket);
      if (outranks && o.id is NpcCar) _playerYieldTargets.add(o.id as NpcCar);
    }
    _playerShouldYield = _playerYieldTargets.isNotEmpty;
    return released;
  }

  /// Set by [_arbitrateAllWayStop]: a conflicting vehicle has the right of way
  /// over the player right now.
  bool _playerShouldYield = false;

  /// The NPCs that currently have the right of way over the player — the ones
  /// that get a red "!" marker if the player fails to yield.
  final List<NpcCar> _playerYieldTargets = [];

  /// Set after arbitration: the arbiter has released the player to proceed.
  bool _playerReleased = false;

  bool _playerMustWait = false;

  /// A pedestrian on/entering a zebra is ahead of the player (urban crosswalks).
  bool _pedBlockingPlayer = false;

  @override
  bool get playerMustWait => _playerMustWait;

  /// The intersection grades right-of-way itself; the generic cut-off detector
  /// only adds false positives here (a fresh car queueing behind the waiting
  /// player), so it's suppressed for the whole tile. (No player lane changes
  /// happen on a single-lane intersection, so nothing legitimate is lost.)
  @override
  bool get suppressDriverReactions => true;

  // ---------------------------------------------------------------------------
  // Crossing-pedestrian detection — only pedestrians actually ON (or stepping
  // onto) a zebra count, never ones strolling a sidewalk parallel to traffic.
  // ---------------------------------------------------------------------------

  /// Widening of a zebra's detection box beyond the painted stripes, so a
  /// pedestrian about to step onto it (off the curb) is yielded to as well.
  static const double _zebraEnterMargin = 12.0; // along the crossing (ends)
  static const double _zebraBandMargin = _crosswalkHalf + 8.0; // across (band)

  /// Which of the four zebra detection bands tile-local [p] lies on — 0 = south,
  /// 1 = north, 2 = west, 3 = east — or -1 if none. The band is the painted
  /// stripe widened beyond it (±[_zebraEnterMargin] along the crossing so a
  /// pedestrian about to step off the curb counts, ±[_zebraBandMargin] across),
  /// i.e. the *detection box* drawn by [_drawZebraDebug]. A zebra spans the road
  /// it crosses and is a thin band at ±[_crosswalkOffset] from the centre.
  int _zebraIndexOf(Vector2 p) {
    final dx = p.x - _cx, dy = p.y - _cy;
    // South/North zebras cross the vertical road (x within the road span).
    if (dx.abs() <= _halfBox + _zebraEnterMargin) {
      if ((dy - _crosswalkOffset).abs() <= _zebraBandMargin) return 0; // south
      if ((dy + _crosswalkOffset).abs() <= _zebraBandMargin) return 1; // north
    }
    // East/West zebras cross the horizontal road (y within the road span).
    if (dy.abs() <= _halfBox + _zebraEnterMargin) {
      if ((dx + _crosswalkOffset).abs() <= _zebraBandMargin) return 2; // west
      if ((dx - _crosswalkOffset).abs() <= _zebraBandMargin) return 3; // east
    }
    return -1;
  }

  /// Whether tile-local [p] is on any of the four zebra detection bands.
  bool _pedOnZebra(Vector2 p) => _zebraIndexOf(p) >= 0;

  /// THE pedestrian hazard probe — the one mechanism for "is a crossing
  /// pedestrian in my way, and how far ahead?". Walks [sp] forward from
  /// [travelled] and returns the distance to the NEAR EDGE of the first zebra
  /// crossing ahead that has a CONFLICTING pedestrian — i.e. a fixed hold line
  /// before the busy crossing — or null if clear. It holds at the crossing's
  /// edge, NOT at the pedestrian's body: targeting the body let a car nuzzle up
  /// to whoever was nearest and creep forward almost into the next pedestrian as
  /// a queue shuffled across.
  ///
  /// A pedestrian on the crossing the path is on conflicts when EITHER they are
  /// already within [kPedYieldLateral] of the path (in this lane — also catches a
  /// stationary or dead-centre walker) OR they are walking TOWARD the path point
  /// ("moving the car's way"), so a car yields to someone crossing in from the
  /// far half, not only one already in its lane. This is the same standard the
  /// player's give-way fault ([_playerCuttingOffPed]) holds the player to — NPC
  /// cars yield exactly when the player would be faulted for not. (The
  /// walking-toward term is currently unbounded in distance, so an NPC yields the
  /// instant a ped steps onto the far end heading its way; bound it by distance
  /// if that reads as freezing too early.)
  ///
  /// Used identically by NPC cars and the player wait flag. Because it walks the
  /// *actual path* it follows turns for free (a left-turn's exit crossing is just
  /// further along the spline), and because it is re-run every frame it re-holds
  /// for a pedestrian who steps on after the agent has rolled forward. It SKIPS
  /// the crossing the reference point is currently inside — commit & clear, so a
  /// car never freezes straddling the stripes. The per-pedestrian band index
  /// scopes the conflict tests to the crossing the path is on, so a stroller on a
  /// crossing road can't false-trip a car on the parallel lane.
  double? _pedStopOnPath(
      Spline sp, double travelled, List<Pedestrian> pedestrians) {
    if (pedestrians.isEmpty) return null;
    final total = sp.totalLength;
    if (total <= 0) return null;

    // Pedestrians physically on a zebra band, in tile-local coords, each tagged
    // with its band index and its walking direction (rotated into tile space).
    // The band index scopes the conflict tests below to the crossing the car's
    // path is actually on; the direction lets the car yield to someone walking
    // INTO its path from across the road, not only one already in its lane.
    final zebraPeds = <({Vector2 pos, Vector2 fwd, int band})>[];
    for (final ped in pedestrians) {
      final local = worldToLocal(ped.position);
      final band = _zebraIndexOf(local);
      if (band < 0) continue;
      zebraPeds.add((
        pos: local,
        fwd: directionToLocal(
            Vector2(math.cos(ped.angle), math.sin(ped.angle))),
        band: band,
      ));
    }
    if (zebraPeds.isEmpty) return null; // (only urban junctions reach here)

    // Dropping zebra direction-attribution is safe ONLY while a parallel lane
    // clears every PERPENDICULAR crossing's band by more than the lateral
    // conflict — else a corner-stroller on a crossing road could false-trip this
    // probe (the very thing direction-attribution used to prevent). Holds at the
    // current urban offset (138 → margin 24); a future shrink of
    // [_urbanCrosswalkShift] must keep it true (it was ~4u at the old shift 18).
    assert(
        _crosswalkOffset - kPedYieldLateral - _laneOffset > _zebraBandMargin,
        'crosswalk offset too small: a perpendicular crossing reaches the '
        'parallel lane — corner-strollers would false-trip the pedestrian '
        'probe. Widen _urbanCrosswalkShift or restore direction attribution.');

    const conflict = kPedYieldLateral; // lane half-width — the single knob
    const step = 10.0;
    // Commit through the crossing the reference point is currently ON: skip
    // bands until the path leaves the one (if any) it starts in. A crossing not
    // yet reached is NOT skipped → stop short of it and hold.
    bool committing =
        _pedOnZebra(sp.evaluate((travelled / total).clamp(0.0, 1.0)));
    // The near edge (first on-path point) of the crossing currently being
    // scanned — the FIXED line the car holds at if that crossing is busy. Reset
    // each time the path leaves a crossing, so it always names the one ahead.
    double? bandEntry;
    for (double d = step;
        d <= kPedYieldScanDistance && travelled + d <= total;
        d += step) {
      final pt = sp.evaluate(((travelled + d) / total).clamp(0.0, 1.0));
      final ptBand = _zebraIndexOf(pt);
      if (committing) {
        if (ptBand < 0) committing = false; // left the crossing we were clearing
        continue;
      }
      if (ptBand < 0) {
        bandEntry = null; // off the crossing — reset for the next one ahead
        continue;
      }
      bandEntry ??= d; // first point of this crossing = its near-edge hold line
      for (final p in zebraPeds) {
        if (p.band != ptBand) continue; // only peds on THIS crossing
        // Yield (hold at the near edge, not at the person, so the car never
        // creeps onto a queueing pedestrian) if the pedestrian is either already
        // in this lane — distance within [conflict], which also covers a
        // stationary or dead-centre walker — OR walking TOWARD this path point
        // ("moving the car's way") from anywhere on the crossing, the same
        // standard the player's give-way fault holds the player to. The far-half
        // crosser the old lane-only corridor missed (car started right in front
        // of them) now stops the car.
        if (p.pos.distanceTo(pt) <= conflict ||
            (pt - p.pos).dot(p.fwd) > 0) {
          return bandEntry;
        }
      }
    }
    return null;
  }

  /// Whether a zebra crossing lies on [sp] within [lookahead] ahead of
  /// [travelled] (pedestrians aside). Used to KEEP a car at crossing speed while
  /// it is on or approaching a crosswalk on its path — chiefly the exit crosswalk
  /// of a turn, where [_zoneOf] reports `far` (so the in-box speed cap has
  /// dropped) yet the car is still sweeping over the stripes. Position-only, like
  /// [_pedOnZebra]; cheap (coarse 10u steps over a short span).
  bool _crossingAhead(Spline sp, double travelled, double lookahead) {
    final total = sp.totalLength;
    if (total <= 0) return false;
    for (double d = 0; d <= lookahead && travelled + d <= total; d += 10.0) {
      if (_pedOnZebra(sp.evaluate(((travelled + d) / total).clamp(0.0, 1.0)))) {
        return true;
      }
    }
    return false;
  }

  /// The nearer of two optional stop-target distances (smaller wins; null = no
  /// stop). Lets the all-way-stop hold and the pedestrian probe be folded into
  /// the single [NpcBrain.stopTargetDistance] the brain brakes to.
  static double? _nearerStop(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

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
  bool _yieldViolationFired = false;
  bool _stopLineCrossed = false;
  bool _clearedReported = false;

  /// Whether the player came to a complete stop during the approach, and the
  /// slowest speed seen (for the fault message). Tracked across the whole
  /// approach window — not just the instant of crossing — so a stop made a
  /// little before the line, or an early stop followed by a creep, still counts.
  bool _cameToStop = false;
  double _minApproachSpeed = double.infinity;

  /// Whether the player's car is physically ON zebra band [idx] — i.e. it has
  /// driven onto (committed to) that crossing. Samples three points along the car
  /// (nose, centre, tail), so the whole time any part of the car straddles the
  /// thin band counts, not just the instant its centre is on it. This replaces a
  /// single nose-point test, whose window was a few frames for a fast car.
  bool _playerOnBand(PlayerCar playerCar, int idx) {
    final fwd = Vector2(math.cos(playerCar.angle), math.sin(playerCar.angle));
    for (final s in const [kCarLength / 2, 0.0, -kCarLength / 2]) {
      if (_zebraIndexOf(worldToLocal(playerCar.position + fwd * s)) == idx) {
        return true;
      }
    }
    return false;
  }

  /// The crossing pedestrian the player is failing to give way to, or null — the
  /// basis for the give-way fault. The rule, in the user's words: a pedestrian in
  /// the zebra's BOUNDING BOX who is MOVING THE PLAYER'S WAY, when the player goes
  /// instead of yielding. Two signals, OR'd (a ped triggers it either way):
  ///   (a) PROXIMITY — the ped is in the player's personal-space bubble
  ///       ([Pedestrian.startledByPlayer], car body within [kPedPersonalSpace]).
  ///       Covers a ped dead in the path, where the direction test degenerates.
  ///   (b) THE ZEBRA BOX — the player has driven onto the SAME band the ped is on
  ///       ([_playerOnBand]: committed to the crossing; a yielder stops BEHIND it)
  ///       and the ped is walking TOWARD the player ("the player's way").
  /// This deliberately uses the FULL band as the zone — NOT a lane-width corridor.
  /// The old corridor (`perp <= kPedYieldLateral`) excluded a ped crossing from
  /// the OTHER half until it had nearly reached the player's lane (the road is
  /// ~2× that corridor wide), so two pedestrians walking in from the far side —
  /// exactly the reported miss — never registered. The direction test is now
  /// "walking toward the player" (`pedFwd · (player − ped) > 0`), which does NOT
  /// sign-flip as the ped crosses the lane centre (the old `perp`-based test did,
  /// dropping the ped right as it entered the path). Pass-behind (a ped walking
  /// AWAY toward the far curb) gives a negative dot → excluded; a stopped player
  /// can't fail (the caller gates on MOVING); a ped on a perpendicular crossing
  /// has a different band index → excluded. Hitting one is a separate collision.
  Pedestrian? _playerCuttingOffPed(
      PlayerCar playerCar, List<Pedestrian> pedestrians) {
    if (pedestrians.isEmpty) return null;
    for (final ped in pedestrians) {
      final idx = _zebraIndexOf(worldToLocal(ped.position));
      if (idx < 0) continue; // not on any crossing
      // (a) Proximity — right in the player's way (also the dead-centre case).
      if (ped.startledByPlayer) return ped;
      // (b) The zebra box — the player drove onto the ped's crossing and the ped
      // is walking toward the player.
      if (!_playerOnBand(playerCar, idx)) continue;
      final toPlayer = playerCar.position - ped.position;
      final pedFwd = Vector2(math.cos(ped.angle), math.sin(ped.angle));
      if (pedFwd.dot(toPlayer) > 0) return ped; // coming the player's way
    }
    return null;
  }

  /// The player's at-line verdict — shared by both controls. The approach state
  /// machine (far-south reset, safe-clear pass, the stop-credit tracking and the
  /// single line-crossing edge) is identical; only what is judged AT the line
  /// differs: an all-way stop checks for a complete stop + give-way, a traffic
  /// light checks the phase (crossing on red = ran the light).
  void _checkPlayerApproach(PlayerCar playerCar) {
    final playerLocal = worldToLocal(playerCar.position);
    final localY = playerLocal.y;

    // Genuinely far south of the box — reset the whole approach state. Reset at
    // the approach distance (not a few units before the line) so the stop
    // credit spans the entire run-up to the sign.
    if (localY > _playerStopLineY + _approachDistance) {
      _playerViolationFired = false;
      _yieldViolationFired = false;
      _stopLineCrossed = false;
      _clearedReported = false;
      _cameToStop = false;
      _playerDemoted = false;
      _minApproachSpeed = double.infinity;
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

    // While approaching the line, watch for a complete stop and remember the
    // slowest speed for the fault message. The stop only *counts* when made
    // near the line (within [_stopCreditWindow]) — a stop made far back in the
    // run-up then accelerating through the painted line is a rolling stop, not a
    // legal one. The window is generous enough to credit a car stopped with its
    // nose at the line (centre ~kCarLength/2 + setback behind it) and a short
    // creep, but not a stop a few car-lengths early.
    if (!_stopLineCrossed) {
      _minApproachSpeed = math.min(_minApproachSpeed, playerCar.speed);
      if (playerCar.speed <= kStopSpeedThreshold &&
          localY <= _playerStopLineY + _stopCreditWindow) {
        _cameToStop = true;
      }
    }

    // The painted line is the decision point — evaluated once as the player
    // crosses it, where the player COMMITS. (Sampling later, at the box edge,
    // doesn't work: in urban the line sits ~102u back, and by the time the player
    // covers that the dynamic arbitration has cleared every conflict — the fault
    // would never fire.) Two independent faults can be raised here:
    //   - stop-sign: no complete stop was made (mandatory regardless of
    //     traffic — the whole all-way-stop lesson);
    //   - fail-to-yield: the player crossed while a conflicting car had the
    //     right of way. A car ALREADY CROSSING the box is exempted upstream (see
    //     [_playerYieldTargets]) — it's on its way out and a player still at the
    //     line will reach the junction after it clears — so this fires only for
    //     an APPROACHING priority car (the genuine queue-jump).
    if (!_stopLineCrossed && localY <= _playerStopLineY) {
      _stopLineCrossed = true;
      scenario.onPlayerPassedYieldLine(playerCar.speed);

      if (control == IntersectionControl.trafficLight) {
        // Crossing the stop line on a solid red = ran the light. Yellow is still
        // legal to proceed (no dilemma-zone grading); green is clean. A car that
        // entered on green and is caught in the box by the change isn't faulted —
        // the verdict is taken once, here, at the line.
        if (_phaseOf(Heading.north) == SignalPhase.red &&
            !_playerViolationFired) {
          _playerViolationFired = true;
          debugPrint('[INTERSECTION] red-light violation @ line: '
              'speed=${playerCar.speed.toStringAsFixed(0)}');
          GameBus.instance.emit(RedLightViolationEvent());
        }
      } else {
        if (!_cameToStop && !_playerViolationFired) {
          _playerViolationFired = true;
          debugPrint('[INTERSECTION] stop-sign violation @ line: '
              'minSpeed=${_minApproachSpeed.toStringAsFixed(0)}');
          GameBus.instance.emit(
              StopSignViolationEvent(minSpeedObserved: _minApproachSpeed));
        }

        if (_playerShouldYield && !_playerReleased && !_yieldViolationFired) {
          _yieldViolationFired = true;
          debugPrint('[INTERSECTION] fail-to-yield @ line: '
              'speed=${playerCar.speed.toStringAsFixed(0)}');
          GameBus.instance
              .emit(YieldViolationEvent(speedAtLine: playerCar.speed));
          _markYieldTargets(playerCar);
        }
      }
    }
  }

  /// Pedestrians the player has already been faulted for cutting off this run, so
  /// each crossing logs ONE give-way fault instead of one per frame. Pruned to
  /// live pedestrians every frame — a culled crosser drops out, a fresh crosser
  /// is a new identity — so it stays small without a per-traversal reset.
  final Set<Pedestrian> _gaveWayFaulted = {};

  /// Failed-to-give-way to a crossing pedestrian — logged INDEPENDENTLY of the
  /// stop-sign approach state machine in [_checkPlayerApproach]. The crossings sit
  /// OUTSIDE the conflict box (all four approaches: the zebra bands span ~120–156
  /// from centre, the box edge is at [_halfBox]=80), so every EXIT crossing of a
  /// turn/straight maneuver happens after [_playerExitedBox] is already true.
  /// [_checkPlayerApproach] early-returns there (correctly, for the stop line), which
  /// silently dropped every exit-crossing fault — the bug where the startle "!"
  /// popped (TileManager, global) but nothing reached the faults log. So this runs
  /// every frame instead: [_playerCuttingOffPed] is already scoped to this tile's
  /// zebra bands, and the player-MOVING gate keeps a stopped, yielding car clean.
  /// [_playerCuttingOffPed] combines BOTH yield signals (proximity bubble + the
  /// zebra-crossing direction test); deduped per pedestrian so each crossing of a
  /// traversal (entry near-side and an exit) faults at most once.
  void _checkPedestrianGiveWay(
      PlayerCar playerCar, List<Pedestrian> pedestrians) {
    _gaveWayFaulted.retainWhere(pedestrians.contains); // drop culled crossers
    if (playerCar.speed <= kStopSpeedThreshold) return; // stopped = yielding
    final cutOff = _playerCuttingOffPed(playerCar, pedestrians);
    if (cutOff == null || !_gaveWayFaulted.add(cutOff)) return; // already faulted
    debugPrint('[INTERSECTION] failed to give way to pedestrian '
        '(cut across their crossing): '
        'speed=${playerCar.speed.toStringAsFixed(0)}');
    GameBus.instance
        .emit(PedestrianYieldViolationEvent(speedAtLine: playerCar.speed));
    // Ensure a logged fault always has a visible "!": on a GAP cut-off the
    // proximity startle (TileManager) never fired (the car stayed outside
    // kPedPersonalSpace), so add the bubble here when the ped isn't already
    // startled.
    final world = parent;
    if (world != null && !cutOff.startledByPlayer) {
      world.add(ReactionBubble(
        target: cutOff,
        player: playerCar,
        reaction: DriverReaction.failedToYield,
      ));
    }
  }

  /// Drop a red "!" marker on every driver that had the right of way when the
  /// player crossed out of turn. Added to the tile's parent — the world — so
  /// each bubble lives in world space and follows its NPC, exactly like the
  /// cut-off reaction. The marker is locked to the direction the player drives
  /// *through this box* — i.e. the tile's local "north" (−y) rotated into world
  /// space by the tile's placement, so it reads correctly even when the
  /// intersection is placed rotated (downstream of a turn).
  void _markYieldTargets(PlayerCar playerCar) {
    final world = parent;
    if (world == null) return;
    final northWorld = directionToWorld(Vector2(0, -1));
    final northAngle = math.atan2(northWorld.y, northWorld.x);
    for (final npc in _playerYieldTargets) {
      world.add(ReactionBubble(
        target: npc,
        player: playerCar,
        reaction: DriverReaction.failedToYield,
        fixedAngle: northAngle,
      ));
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
    _drawCurbReturns(canvas); // round the inner corners cars turn around
    _drawMarkings(canvas);
    _drawStopLines(canvas);
    _drawCrosswalks(canvas); // urban zebras (no-op interurban)
    if (kDebugMode && DebugState.showDebug) _drawZebraDebug(canvas); // detection box overlay
    drawDecorations(canvas); // grass-corner scenery
    if (control == IntersectionControl.trafficLight) {
      _drawSignalHeads(canvas); // cycling lights instead of STOP signs
    } else {
      _drawStopSigns(canvas);
    }
    debugRenderSplines(canvas);
    if (kDebugMode && DebugState.showDebug) _drawDebugTurns(canvas);
  }

  /// Player's tile-local position, cached each frame for the debug overlay.
  Vector2? _debugPlayerLocal;

  /// Pedestrians, cached each frame (debug only) for the zebra-box overlay.
  List<Pedestrian> _debugPeds = const [];

  /// DEBUG: paints each zebra's *detection box* — the widened band
  /// [_zebraIndexOf] tests, not just the painted stripes — at heavy opacity, so
  /// the actual "is this crossing busy?" geometry is visible. Red when a
  /// pedestrian is on it (busy), amber when clear.
  void _drawZebraDebug(Canvas canvas) {
    if (locale != LocaleType.urban) return;
    for (int idx = 0; idx < 4; idx++) {
      final r = _zebraBandRect(idx);
      // Busy = a pedestrian physically on this zebra band — matches the probe's
      // positional [_pedOnZebra] test.
      final busy = _debugPeds
          .any((ped) => _zebraIndexOf(worldToLocal(ped.position)) == idx);
      canvas.drawRect(
          r,
          Paint()
            ..color =
                busy ? const Color(0x99FF1744) : const Color(0x55FFC400));
      canvas.drawRect(
          r,
          Paint()
            ..color = busy ? const Color(0xFFFF1744) : const Color(0xCCFFC400)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  /// Tile-local rect of zebra detection band [idx] (0=S,1=N,2=W,3=E) — matches
  /// the bounds tested in [_zebraIndexOf].
  Rect _zebraBandRect(int idx) {
    const along = _halfBox + _zebraEnterMargin; // road span + step-on margin
    switch (idx) {
      case 0: // south (horizontal band)
        return Rect.fromLTRB(_cx - along, _cy + _crosswalkOffset - _zebraBandMargin,
            _cx + along, _cy + _crosswalkOffset + _zebraBandMargin);
      case 1: // north
        return Rect.fromLTRB(_cx - along, _cy - _crosswalkOffset - _zebraBandMargin,
            _cx + along, _cy - _crosswalkOffset + _zebraBandMargin);
      case 2: // west (vertical band)
        return Rect.fromLTRB(_cx - _crosswalkOffset - _zebraBandMargin, _cy - along,
            _cx - _crosswalkOffset + _zebraBandMargin, _cy + along);
      default: // east
        return Rect.fromLTRB(_cx + _crosswalkOffset - _zebraBandMargin, _cy - along,
            _cx + _crosswalkOffset + _zebraBandMargin, _cy + along);
    }
  }

  /// DEBUG: floats each vehicle's **place in line** beside it — 1 = next to go,
  /// 2 = after that … — or "GO" once released. This is the rank among the cars
  /// currently holding a turn ticket (not the raw global ticket counter, which
  /// climbs forever as cars respawn), so it stays small and intuitive. Tickets
  /// are claimed on *approach* (a car stopped frontmost at the line), never at
  /// spawn; this overlay makes the order observable.
  void _drawDebugTurns(Canvas canvas) {
    // Rank everyone still waiting (ticketed, not yet released) by arrival.
    final waiting = _ticket.keys.where((id) => !_granted.contains(id)).toList()
      ..sort((a, b) => _ticket[a]!.compareTo(_ticket[b]!));
    final place = {for (int i = 0; i < waiting.length; i++) waiting[i]: i + 1};

    for (final npc in npcs) {
      _drawTurnLabel(canvas, worldToLocal(npc.position), place[npc],
          _granted.contains(npc), isPlayer: false);
    }
    final pl = _debugPlayerLocal;
    if (pl != null) {
      _drawTurnLabel(canvas, pl, place[_playerId], _playerReleased,
          isPlayer: true);
    }
  }

  void _drawTurnLabel(Canvas canvas, Vector2 pos, int? place, bool go,
      {required bool isPlayer}) {
    final String text;
    final Color color;
    if (go) {
      text = isPlayer ? 'YOU GO' : 'GO';
      color = const Color(0xFF4CAF50);
    } else if (place != null) {
      text = isPlayer ? 'YOU $place' : '$place';
      color = const Color(0xFFFFD600);
    } else {
      return; // hasn't claimed a turn yet
    }
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Just off the car's right side (tile-local +x), vertically centred.
    final left = Offset(pos.x + 20, pos.y - tp.height / 2);
    final bg = Rect.fromLTWH(left.dx - 4, left.dy - 2, tp.width + 8, tp.height + 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(4)),
      Paint()..color = const Color(0xCC000000),
    );
    tp.paint(canvas, left);
  }

  /// Radius of the red octagonal STOP signs.
  static const double _signRadius = 30.0;

  /// How far *before* the stop line (toward the approaching driver) the sign
  /// sits, measured along the approach.
  static const double _signSetback = 60.0;

  /// One STOP sign per approach, on the road surface in the right-hand lane,
  /// a little before the stop line.
  void _drawStopSigns(Canvas canvas) {
    _drawStopSignFor(canvas, const Offset(0, -1)); // S approach → N-bound
    _drawStopSignFor(canvas, const Offset(0, 1)); //  N approach → S-bound
    _drawStopSignFor(canvas, const Offset(1, 0)); //  W approach → E-bound
    _drawStopSignFor(canvas, const Offset(-1, 0)); // E approach → W-bound
  }

  /// Places and orients one sign for traffic travelling along [travel].
  /// Centred in the right-hand (approaching) lane on the road surface.
  void _drawStopSignFor(Canvas canvas, Offset travel) {
    final right = Offset(-travel.dy, travel.dx);
    const outward = _laneOffset; // centre of the right-hand lane
    final back = _halfBox + _stopLineGap + _signSetback;
    final center = const Offset(_cx, _cy) - travel * back + right * outward;
    final angle = math.atan2(travel.dx, -travel.dy);
    _drawStopSign(canvas, center, angle);
  }

  void _drawStopSign(Canvas canvas, Offset center, double angle) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    const r = _signRadius;
    final octagon = Path();
    for (int i = 0; i < 8; i++) {
      final a = (22.5 + 45.0 * i) * math.pi / 180.0;
      final p = Offset(r * math.cos(a), r * math.sin(a));
      i == 0 ? octagon.moveTo(p.dx, p.dy) : octagon.lineTo(p.dx, p.dy);
    }
    octagon.close();
    canvas.drawPath(octagon, Paint()..color = const Color(0xFFD32F2F));
    canvas.drawPath(
        octagon,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);

    final tp = _stopText;
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  /// Laid out once and reused — text/style never change.
  static final TextPainter _stopText = TextPainter(
    text: const TextSpan(
      text: 'STOP',
      style: TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 15,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.5,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  // ---------------------------------------------------------------------------
  // Traffic-light signal heads (traffic-light control only)
  // ---------------------------------------------------------------------------

  static const double _signalLampRadius = 8.0;

  /// One signal head per approach, on the near-side curb to the right of the
  /// approaching lane, each showing that approach's live phase.
  void _drawSignalHeads(Canvas canvas) {
    _drawSignalHeadFor(canvas, const Offset(0, -1), _phaseOf(Heading.north));
    _drawSignalHeadFor(canvas, const Offset(0, 1), _phaseOf(Heading.south));
    _drawSignalHeadFor(canvas, const Offset(1, 0), _phaseOf(Heading.east));
    _drawSignalHeadFor(canvas, const Offset(-1, 0), _phaseOf(Heading.west));
  }

  /// Places and orients one head for traffic travelling along [travel]: just
  /// before the stop line (near-side), out on the curb right of the lane.
  void _drawSignalHeadFor(Canvas canvas, Offset travel, SignalPhase phase) {
    final right = Offset(-travel.dy, travel.dx);
    final back = _halfBox + _stopLineGap + _signSetback;
    const outward = _halfBox + 14.0; // on the pavement, right of the lane
    final center = const Offset(_cx, _cy) - travel * back + right * outward;
    final angle = math.atan2(travel.dx, -travel.dy);
    _drawSignalHead(canvas, center, angle, phase);
  }

  void _drawSignalHead(
      Canvas canvas, Offset center, double angle, SignalPhase phase) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    final housing = RRect.fromRectAndRadius(
        const Rect.fromLTRB(-13, -30, 13, 30), const Radius.circular(6));
    canvas.drawRRect(housing, Paint()..color = const Color(0xFF202225));
    canvas.drawRRect(
        housing,
        Paint()
          ..color = const Color(0xFF0A0A0B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);

    // Red toward the box, green nearest the driver — colour is what reads.
    _drawLamp(canvas, const Offset(0, -18), phase == SignalPhase.red,
        on: const Color(0xFFFF1744),
        glow: const Color(0x55FF1744),
        off: const Color(0xFF3A1417));
    _drawLamp(canvas, const Offset(0, 0), phase == SignalPhase.yellow,
        on: const Color(0xFFFFC400),
        glow: const Color(0x55FFC400),
        off: const Color(0xFF3A3211));
    _drawLamp(canvas, const Offset(0, 18), phase == SignalPhase.green,
        on: const Color(0xFF00E676),
        glow: const Color(0x5500E676),
        off: const Color(0xFF123A22));

    canvas.restore();
  }

  void _drawLamp(Canvas canvas, Offset at, bool lit,
      {required Color on, required Color glow, required Color off}) {
    if (lit) {
      canvas.drawCircle(
          at, _signalLampRadius + 5, Paint()..color = glow);
    }
    canvas.drawCircle(
        at, _signalLampRadius, Paint()..color = lit ? on : off);
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kTileSize, kTileSize),
      Paint()..color = groundColor,
    );
  }

  /// Zebra crossings on all four approaches — urban only. Stripes run parallel
  /// to the traffic that would stop for them (vertical bars on the N/S
  /// approaches, horizontal bars on the E/W approaches).
  void _drawCrosswalks(Canvas canvas) {
    if (locale != LocaleType.urban) return;
    final paint = Paint()..color = const Color(0xFFFFFFFF);
    _zebra(canvas, paint, _cy + _crosswalkOffset, horizontalBand: true);
    _zebra(canvas, paint, _cy - _crosswalkOffset, horizontalBand: true);
    _zebra(canvas, paint, _cx + _crosswalkOffset, horizontalBand: false);
    _zebra(canvas, paint, _cx - _crosswalkOffset, horizontalBand: false);
  }

  void _zebra(Canvas canvas, Paint paint, double centreAlong,
      {required bool horizontalBand}) {
    const stripe = 12.0, gap = 10.0;
    const roadMin = _cx - _halfBox; // 520 (same for cy by symmetry)
    const roadMax = _cx + _halfBox; // 680
    if (horizontalBand) {
      final top = centreAlong - _crosswalkHalf;
      for (double x = roadMin + 4; x + stripe <= roadMax; x += stripe + gap) {
        canvas.drawRect(
            Rect.fromLTWH(x, top, stripe, _crosswalkHalf * 2), paint);
      }
    } else {
      final left = centreAlong - _crosswalkHalf;
      for (double y = roadMin + 4; y + stripe <= roadMax; y += stripe + gap) {
        canvas.drawRect(
            Rect.fromLTWH(left, y, _crosswalkHalf * 2, stripe), paint);
      }
    }
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

  /// Rounds the four INNER corners — where a pavement corner pokes into the
  /// conflict box and turning traffic sweeps past — by shaving the sharp 90° tip
  /// off the pavement and repainting it road colour, leaving a rounded curb
  /// return. (The grass-side corners are handled by [_drawRoundedCurbs].) Each
  /// ([sx], [sy]) points from the box corner OUT into its pavement-corner block.
  void _drawCurbReturns(Canvas canvas) {
    final road = Paint()..color = const Color(0xFF424242);
    const lo = _cx - _halfBox; // 520 — box near edge
    const hi = _cx + _halfBox; // 680 — box far edge / pavement inner edge
    _curbWedge(canvas, hi, hi, 1, 1, road, _curbReturnRadius); // SE
    _curbWedge(canvas, lo, hi, -1, 1, road, _curbReturnRadius); // SW
    _curbWedge(canvas, hi, lo, 1, -1, road, _curbReturnRadius); // NE
    _curbWedge(canvas, lo, lo, -1, -1, road, _curbReturnRadius); // NW
  }

  /// Fills the wedge between a sharp corner at ([cornerX], [cornerY]) and a
  /// quarter-circle arc of radius [r] (default [_curbRadius]), where ([sx], [sy])
  /// point from the corner into the quadrant being rounded off.
  void _curbWedge(Canvas canvas, double cornerX, double cornerY, int sx, int sy,
      Paint p, [double r = _curbRadius]) {
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
    final g = _stopLineGap;

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
    required this.id,
    required this.heading,
    required this.path,
    required this.localPos,
    required this.speed,
  });

  /// Stable identity for arrival-order bookkeeping: the [NpcCar] instance, or
  /// [IntersectionTile._playerId] for the player.
  final Object id;

  /// Travel heading on the approach.
  final Heading heading;

  /// Tile-local movement path — used for geometric conflict checks.
  final Spline path;

  final Vector2 localPos;
  final double speed;
}
