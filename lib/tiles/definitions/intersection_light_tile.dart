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
import '../scenarios/lane_discipline_scenario.dart';
import 'lane_config.dart';

/// Travel heading through the intersection. Ordered to match the 4-fold
/// rotational symmetry: the south approach (player, heading [north]) maps onto
/// east/south/west by `_rotateQuarters(p, k)` with k = heading index.
enum _Heading { north, east, south, west }

/// The lane-discipline fault a box traversal earns, or null for a clean run.
/// Ordered by priority — the grade reports the first that applies: MISSED THE
/// TURN (ended up somewhere other than the instruction) dominates a wrong lane
/// (the RIGHT move from the wrong lane), which dominates a wrong exit lane (right
/// move + lane, far lane instead of nearest).
enum LaneFault { missedTurn, wrongLane, wrongExitLane }

/// What crossing the box gate against the signal earns (null = clean): ran a red
/// (or rolled a right-on-red without stopping), or ran a yellow you could have
/// stopped for. The stop-line-encroachment fault is positional, judged separately.
enum SignalGateFault { ranRed, ranYellow }

/// A 2-lane-each-way, **traffic-light** intersection that teaches **lane
/// discipline** on top of signal compliance.
///
/// Geometry is the 2-lane road's (lane centres 640/720 player, 560/480
/// oncoming, a 320-wide road / box) so it is lane-continuous with the existing
/// 2-lane straight road and slots into free-drive after one. Unlike the 1-lane
/// [IntersectionTile] (which carries the all-way-stop ticketing arbiter) this
/// tile is **light-only** — the signal phase arbitrates the box, so there is no
/// ticketing to perturb.
///
/// The exam task is lane discipline: each run picks a [LaneConfig] (what each
/// lane is for) and commands a RANDOM maneuver from its pool in [bindPlayerEntry];
/// the player must be in a legal lane AND actually perform it (graded on the way
/// out — wrong lane / didn't follow it / wrong exit lane). The painted arrows and
/// overhead placards advertise the active config; the L1 preset is inner =
/// left-only ◄, outer = through+right ▲►.
///
/// The TURN is chosen with the wheel via TURN TAPS on a continuous spine: the player
/// follows ONE whole through-lane spline per lane (entry to exit), and the turns hang
/// on it as branches ([playerBranches], resolved per-frame by TileManager); crossing a
/// tap while leaning toward it diverts onto that turn (the branch starts ON the spine,
/// so the switch is position-continuous); crossing it neutral stays straight on the
/// spine. Inner lane carries the left turns, outer the right turns (merge-first). Near
/// and far are just two taps at two depths. Because the spine is never chopped, the
/// corridor merge ([playerLaneMates]) never hits a seam. Steering (the kIntentionLean
/// lean) is ALWAYS on; the box is purely a rules region.
class IntersectionLightTile extends TileBase {
  IntersectionLightTile({
    super.locale,
    ScenarioBase? scenario,
    math.Random? rng,
    LaneConfig? config,
  })  : _rng = rng ?? math.Random(),
        super(
          tileType: TileType.intersectionLight,
          scenario: scenario ?? LaneDisciplineScenario(),
          size: Vector2(_w, _h),
        ) {
    // The lane layout for this run: injected (tests/curriculum), a test-mode
    // override (integration tests run through the registry/[TileManager], which
    // can't inject a config per tile), else a random preset. Picked once; the
    // renderer, the player branches and the grader all read it, so the layout is
    // graded, not just painted.
    _config = config ??
        debugConfigOverride ??
        LaneConfig.presets[_rng.nextInt(LaneConfig.presets.length)];
  }

  final math.Random _rng;
  late final LaneConfig _config;

  /// Test-only override for the random lane-config pick, so integration tests
  /// that drive a specific turn through the registry/[TileManager] stay
  /// deterministic. Null in production (a real run gets a random preset).
  @visibleForTesting
  static LaneConfig? debugConfigOverride;

  /// The commanded maneuver — late-bound in [bindPlayerEntry] to a uniformly
  /// random pick from the active config's commandable pool. Defaults to straight
  /// until bound.
  Maneuver _maneuver = Maneuver.straight;
  bool _maneuverBound = false;

  /// The exit the player ACTUALLY takes — the branch they committed to at the box
  /// mouth with the wheel (the wheel wins: you can turn from any lane). Drives
  /// [exitAnchor]/[exitDirection] — where the next tile is placed — so it is
  /// finalised at the gate (see [_checkPlayerApproach]), not at the command. The
  /// anchor always uses the CANONICAL (inner) lane position so the receiving road
  /// stays fixed regardless of which lane the player exits from — a lane-matched
  /// anchor would shift the whole next tile sideways (swinging its oncoming lanes
  /// over the seam). Exiting off the canonical lane just lands the car a lane over
  /// on the next tile, which is continuous; it self-corrects with normal steering.
  Maneuver _committedExit = Maneuver.straight;

  @override
  Maneuver? get commandedManeuver => _maneuver;

  static void register() {
    TileRegistry.register(
      TileType.intersectionLight,
      (ctx) => IntersectionLightTile(locale: ctx.locale, rng: ctx.rng),
      entryLanes: 2,
      exitLanes: 2,
      junction: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Geometry — built on the 2-lane road's lane centres so the seam lines up.
  // ---------------------------------------------------------------------------

  // The tile is the 2-lane road's WIDTH (so the N-S lanes seam at 640/720) but
  // TALLER, so the player's approach AND exit roads are ~1.5× a square tile's.
  // The box stays centred (cx, cy) = the tile centre, so the 4 approaches are
  // symmetric about it even though the bounding box isn't square.
  static const double _w = kTileSize; // 1200 — width (seam-aligned)
  static const double _h = 1640.0; // height: approach 660 + box 320 + exit 660
  static const double _cx = _w / 2; // 600 — N-S road centre
  static const double _cy = _h / 2; // 820 — E-W road / box centre
  static const double _half = kLaneWidth * 2; // 160 — road half-width AND box half
  static const double _innerOff = kLaneWidth * 0.5; // 40 — inner (centre-side) lane
  static const double _outerOff = kLaneWidth * 1.5; // 120 — outer (curb) lane

  /// Within this distance before the box a car counts for right-of-way.
  static const double _approachDistance = 300.0;

  /// Painted stop line offset from the box edge. Tracks the urban zebra outward
  /// (derived from [_crosswalkOffset]) so a car halted at the line — nose ~a
  /// [kStopLineSetback] before it — still sits clear of the (moved-out) crossing.
  /// Interurban has no crossing → keeps its tight line.
  double get _stopLineGap => locale == LocaleType.urban
      ? _crosswalkOffset + _crosswalkHalf + kStopLineSetback - _half // 90
      : 30.0;

  double get _stopLineFromCentre => _half + _stopLineGap;

  static const double _curbRadius = 80.0;

  /// Radius of the curb return at each inner box-mouth corner — where a pavement
  /// corner pokes into the conflict box and turning traffic sweeps around it.
  /// Kept inside the 40-wide pavement corner (so it never spills road colour into
  /// the grass), matching the 1-lane intersection's treatment.
  static const double _curbReturnRadius = 36.0;

  // --- Pedestrian crossings (urban only) ------------------------------------
  static const double _crosswalkHalf = 18.0;

  /// Zebra band centre, offset from the tile centre. Pushed clear of the box so
  /// the FOUR crossings' detection bands don't OVERLAP at the box corners — at
  /// +30 a perpendicular crossing's band reached back across the corner, so a
  /// ped strolling one corner was mis-attributed to the cross-street's crossing
  /// and false-tripped NPC yields + the player's give-way fault. Separation holds
  /// while `_crosswalkOffset - _zebraBandMargin > _half + _zebraEnterMargin`
  /// (asserted in [_pedStopOnPath]); +58 gives the same ~20px corner clearance the
  /// 1-lane intersection uses. The stop line + signal heads track it via
  /// [_stopLineGap]. One knob — dial it back if the junction reads too spread.
  static const double _crosswalkOffset = _half + 58.0; // 218 — was 190 (bands overlapped)
  // The box is off-centre vertically vs. horizontally now (cx≠cy), so the
  // sidewalk lines split into X (vertical sidewalks) and Y (horizontal ones).
  static const double _swLoX = _cx - _crosswalkOffset; // 410
  static const double _swHiX = _cx + _crosswalkOffset; // 790
  static const double _swLoY = _cy - _crosswalkOffset; // 630
  static const double _swHiY = _cy + _crosswalkOffset; // 1010

  static List<Vector2> _hLine(double y) => [
        Vector2(0, y),
        Vector2(_w * 0.33, y),
        Vector2(_w * 0.66, y),
        Vector2(_w, y),
      ];
  static List<Vector2> _vLine(double x) => [
        Vector2(x, 0),
        Vector2(x, _h * 0.33),
        Vector2(x, _h * 0.66),
        Vector2(x, _h),
      ];

  late final List<Spline> _crossingSplines = [
    for (final pts in [
      _hLine(_swLoY),
      _hLine(_swHiY),
      _vLine(_swLoX),
      _vLine(_swHiX)
    ]) ...[
      Spline(pts),
      Spline(pts.reversed.toList()),
    ],
  ];

  @override
  List<Spline> get crossingPaths =>
      locale == LocaleType.urban ? _crossingSplines : const [];

  // Grass corners between the two roads (vertical road x∈[400,800], horizontal
  // road y∈[620,1020]).
  @override
  List<Rect> get decorationZones => const [
        Rect.fromLTWH(0, 0, 400, 620),
        Rect.fromLTWH(800, 0, 400, 620),
        Rect.fromLTWH(0, 1020, 400, 620),
        Rect.fromLTWH(800, 1020, 400, 620),
      ];

  @override
  List<Frontage> get buildingFrontages => const [
        Frontage(a: Offset(820, _swHiY), b: Offset(1180, _swHiY), outward: Offset(0, 1)),
        Frontage(a: Offset(20, _swLoY), b: Offset(380, _swLoY), outward: Offset(0, -1)),
        Frontage(a: Offset(_swLoX, 1060), b: Offset(_swLoX, 1600), outward: Offset(-1, 0)),
        Frontage(a: Offset(_swHiX, 40), b: Offset(_swHiX, 580), outward: Offset(1, 0)),
      ];

  // ---------------------------------------------------------------------------
  // Signal
  // ---------------------------------------------------------------------------
  late final TrafficSignalController _signal = TrafficSignalController(
      seed: position.x.round() + position.y.round() * 31);

  bool _isNorthSouth(_Heading h) => h == _Heading.north || h == _Heading.south;
  SignalPhase _phaseOf(_Heading h) => _signal.phaseFor(northSouth: _isNorthSouth(h));

  @override
  void update(double dt) {
    super.update(dt);
    _signal.tick(dt);
  }

  // ---------------------------------------------------------------------------
  // Movement geometry — authored once for the south approach (heading north),
  // generated for the other approaches by 90° rotation.
  // ---------------------------------------------------------------------------

  static Vector2 get _centre => Vector2(_cx, _cy);

  static Vector2 _fwdOf(_Heading h) => switch (h) {
        _Heading.north => Vector2(0, -1),
        _Heading.east => Vector2(1, 0),
        _Heading.south => Vector2(0, 1),
        _Heading.west => Vector2(-1, 0),
      };

  /// Right-hand side of travel (the lane side you drive on, right-hand traffic).
  static Vector2 _rightOf(_Heading h) {
    final f = _fwdOf(h);
    return Vector2(-f.y, f.x);
  }

  static _Heading _rightTurn(_Heading h) => switch (h) {
        _Heading.north => _Heading.east,
        _Heading.east => _Heading.south,
        _Heading.south => _Heading.west,
        _Heading.west => _Heading.north,
      };
  static _Heading _leftTurn(_Heading h) => _rightTurn(_rightTurn(_rightTurn(h)));

  /// Distance from the centre to the tile edge along this heading's travel axis
  /// — the N-S approaches reach the tall edges (cy), the E-W the wide ones (cx).
  static double _edgeOf(_Heading h) =>
      (h == _Heading.north || h == _Heading.south) ? _cy : _cx;

  /// Quarter-arc points from [fromPt] to [toPt] about [centre] (radius
  /// |fromPt−centre|), the short (~90°) way. 12 steps (not 8) so a branch rooted at
  /// the box mouth — where the arc is tangent to north — has its first sampled step
  /// close enough to north that the player-fork join has no perceptible kink.
  static List<Vector2> _arcBetween(Vector2 centre, Vector2 fromPt, Vector2 toPt,
      [int steps = 12]) {
    final r = (fromPt - centre).length;
    final a1 = math.atan2(fromPt.y - centre.y, fromPt.x - centre.x);
    final a2 = math.atan2(toPt.y - centre.y, toPt.x - centre.x);
    var delta = a2 - a1;
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    while (delta < -math.pi) {
      delta += 2 * math.pi;
    }
    return [
      for (int i = 0; i <= steps; i++)
        () {
          final a = a1 + delta * (i / steps);
          return Vector2(centre.x + r * math.cos(a), centre.y + r * math.sin(a));
        }(),
    ];
  }

  /// Control points for maneuver [m] from approach [h], in the lane [off] from
  /// the road centre (inner 40 / outer 120). Authored directly per heading: the
  /// tile is non-square, so a 90° rotation of one approach can't generate the
  /// others (the N-S approaches span the tall edges, the E-W the wide ones). The
  /// in-box turn arcs for the two lanes of a maneuver are concentric, so the two
  /// player paths stay ~80u apart everywhere steering is on — no fork wobble.
  static List<Vector2> _movement(_Heading h, double off, Maneuver m) {
    final c = _centre;
    final f = _fwdOf(h);
    final r = _rightOf(h);
    final e = _edgeOf(h);
    final base = c + r * off; // approach-lane centreline through the box
    switch (m) {
      case Maneuver.straight:
        return [base - f * e, base - f * (e * 0.45), base, base + f * e];
      case Maneuver.right:
        // Tight near-corner turn: concentric arcs about c+(r−f)·_half, radius
        // _half−off (outer 40 / inner 120). Exit into the right-hand road.
        final nf = _rightTurn(h);
        final centre = c + (r - f) * _half;
        final p1 = base - f * _half;
        final exitLane = c + _rightOf(nf) * off;
        final p2 = exitLane + _fwdOf(nf) * _half;
        return [
          base - f * e,
          base - f * (_half + 40),
          ..._arcBetween(centre, p1, p2),
          exitLane + _fwdOf(nf) * (_half + 40),
          exitLane + _fwdOf(nf) * _edgeOf(nf),
        ];
      case Maneuver.left:
        // Wide far turn: concentric arcs about c−(r+f)·_innerOff, radius
        // off+_innerOff (inner 80 / outer 160). Exit into the left-hand road.
        final nf = _leftTurn(h);
        final centre = c + (-r - f) * _innerOff;
        final p1 = base - f * _innerOff;
        final exitLane = c + _rightOf(nf) * off;
        final p2 = exitLane + _fwdOf(nf) * _innerOff;
        return [
          base - f * e,
          base - f * (_half + 80),
          base - f * _half,
          ..._arcBetween(centre, p1, p2),
          exitLane + _fwdOf(nf) * (_half + 40),
          exitLane + _fwdOf(nf) * _edgeOf(nf),
        ];
    }
  }

  // ---------------------------------------------------------------------------
  // Player route — a CHAIN of fork nodes per lane. Each lane offers a NEAR turn
  // (early/shallow) and a FAR turn (late/deep): "turn now → the near exit lane;
  // roll a touch deeper and turn → the far exit lane" — the spline is king, your
  // position picks the lane. Built from [_turn] (a corner-rounding arc) which
  // reproduces the old inner-left / outer-right exactly; aim it at the OTHER exit
  // lane and you get the far turns for free. (NPCs still use [_movement].)
  // ---------------------------------------------------------------------------
  static const double _leftR = kLaneWidth; // 80 — left corner radius (old inner-left)
  static const double _rightR = kLaneWidth * 0.5; // 40 — right radius (old outer-right)

  /// Corner-rounding turn: come up lane [x] heading NORTH, round the corner at radius
  /// [r] into the exit lane at local y=[exitY] ([dir] −1 = left/west, +1 = right/east),
  /// then run to the tile edge. The node (start) is (x, exitY+r), tangent north, so it
  /// joins the straight above it without a kink. `_turn(640,780,-1,80)` reproduces the
  /// old inner-left; `_turn(720,940,1,40)` the old outer-right.
  static List<Vector2> _turn(double x, double exitY, int dir, double r) {
    final node = Vector2(x, exitY + r);
    final centre = Vector2(x + dir * r, exitY + r);
    final arcEnd = Vector2(x + dir * r, exitY);
    final edge = dir < 0 ? 0.0 : _w;
    return [
      ..._arcBetween(centre, node, arcEnd),
      Vector2((arcEnd.x + edge) / 2, exitY),
      Vector2(edge, exitY),
    ];
  }

  static List<Vector2> _straightPts(double x, double fromY, double toY) =>
      [Vector2(x, fromY), Vector2(x, (fromY + toY) / 2), Vector2(x, toY)];

  // Exit lanes (local y): west-bound inner 780 / outer 700; east-bound inner 860 /
  // outer 940. The fork-node depth for a turn is exitY + r (so the arc is tangent
  // north there) — that's why the NEAR turn forks shallow and the FAR turn deep.
  static const double _wInner = _cy - _innerOff; // 780
  static const double _wOuter = _cy - _outerOff; // 700
  static const double _eInner = _cy + _innerOff; // 860
  static const double _eOuter = _cy + _outerOff; // 940

  // INNER lane SPINE (x=640): ONE continuous straight, tile entry (y=1640) → exit
  // (y=0). The two LEFT turns TAP onto it — near-left at y=860, far-left at y=780
  // (the exact points the old stub-ends sat at, so the turn fires identically). The
  // spine is whole, so the corridor merge never hits a seam.
  late final Spline _innerThrough = Spline(_straightPts(_cx + _innerOff, _h, 0));
  late final Spline _nearLeft = Spline(_turn(_cx + _innerOff, _wInner, -1, _leftR));
  late final Spline _farLeft = Spline(_turn(_cx + _innerOff, _wOuter, -1, _leftR));

  // OUTER lane SPINE (x=720): ONE continuous straight. The two RIGHT turns tap on —
  // near-right at y=980, far-right at y=900.
  late final Spline _outerThrough = Spline(_straightPts(_cx + _outerOff, _h, 0));
  late final Spline _nearRight = Spline(_turn(_cx + _outerOff, _eOuter, 1, _rightR));
  late final Spline _farRight = Spline(_turn(_cx + _outerOff, _eInner, 1, _rightR));

  /// Lane-mate groups for the magnetic merge — the lanes you may SLIDE between
  /// because they run side-by-side. The big one is the STRAIGHT CORRIDOR: BOTH lane
  /// spines, each ONE continuous spline the whole tile height (x=640 / 720). Because
  /// they're whole (not chopped into approach/mid/through stubs), the merge search
  /// always sees a continuous neighbour — no seam, no dead-band, no jump. Hanging a
  /// turn on a spine doesn't switch off merging into it; the spine keeps running.
  /// Merge in time → you reach the outer spine before its near tap (you can take its
  /// near turn); merge late → you've passed that tap (only its later turn, or
  /// straight). Past a TURN you're on the W/E exit pair instead.
  late final List<List<Spline>> _exitGroups = [
    [_innerThrough, _outerThrough], // the straight corridor — whole spines
    [_nearLeft, _farLeft], // west-bound exit lanes
    [_nearRight, _farRight], // east-bound exit lanes
  ];

  late final List<Spline> _playerPaths = [_innerThrough, _outerThrough];

  @override
  List<Spline> get playerPaths => _playerPaths;

  /// TURN TAPS: each spine carries a NEAR turn (early) and a FAR turn (late), hung on
  /// at two depths. Cross a tap leaning toward it → take that turn; cross it neutral →
  /// stay straight on the spine; lean later → the next tap. Near and far are the same
  /// kind of thing — just two turns at two points, nothing special. Merge-first still
  /// holds geometrically: left turns hang on the inner spine, right turns on the outer,
  /// so you must be on the matching spine (merge there first) to take that turn.
  @override
  List<Spline> playerBranches(Spline spine) {
    // A lane only offers its turn branches if the config says that lane turns
    // there (left lives on the inner spine, right on the outer); otherwise the
    // lane is straight-through and the player just stays on the spine.
    if (identical(spine, _innerThrough)) {
      return _config.allows(isInner: true, m: Maneuver.left)
          ? [_nearLeft, _farLeft]
          : const [];
    }
    if (identical(spine, _outerThrough)) {
      return _config.allows(isInner: false, m: Maneuver.right)
          ? [_nearRight, _farRight]
          : const [];
    }
    return const [];
  }

  /// Lane-mates for merging, following the spline network: the two through-lane spines
  /// are mates the whole height (the corridor); PAST a turn the exit-lane group
  /// ([_exitGroups]) — the two west-bound lanes or the two east-bound lanes — so the
  /// magnetic merge keeps working after the turn (the spline is king), until hand-off.
  @override
  List<Spline> playerLaneMates(Spline current) {
    for (final g in _exitGroups) {
      if (g.any((s) => identical(s, current))) return g;
    }
    return [current];
  }

  /// Test seam: every player turn spline that actually exists (4). "Straight" is no
  /// longer a spline — it's just staying on a through-lane spine.
  @visibleForTesting
  List<Spline> get playerBranchSplines => [_nearLeft, _farLeft, _nearRight, _farRight];

  /// Debug overlay: every turn branch (the through spines are drawn via playerPaths).
  @override
  List<Spline> get debugExtraSplines =>
      [_nearLeft, _farLeft, _nearRight, _farRight];

  /// Test seam: the NEAR turn for a lane+maneuver, or — for straight — the through
  /// spine itself (straight is no longer a branch, it's staying on the spine). The
  /// FAR turns come from [farBranch].
  @visibleForTesting
  Spline branch({required bool inner, required Maneuver m}) => inner
      ? (m == Maneuver.left ? _nearLeft : _innerThrough)
      : (m == Maneuver.right ? _nearRight : _outerThrough);

  /// Test seam: the FAR (late, other-exit-lane) turn for [m] (left or right).
  @visibleForTesting
  Spline farBranch({required Maneuver m}) =>
      m == Maneuver.left ? _farLeft : _farRight;

  /// Test seam: the through-lane spine for a given lane.
  @visibleForTesting
  Spline approach({required bool inner}) =>
      inner ? _innerThrough : _outerThrough;

  /// The exit DIRECTION committed by [s] — both the near and far turns of a side share
  /// it (the lane you land in doesn't change which way the corridor bends). A through
  /// spine is straight. Drives the late exit re-placement; with the discrete tap it
  /// flips at most once — when the player diverts onto a turn (until then they're on a
  /// straight spine, so it stays Maneuver.straight and nothing churns).
  Maneuver? _exitManeuver(Spline? s) {
    if (s == null) return null;
    if (identical(s, _nearLeft) || identical(s, _farLeft)) return Maneuver.left;
    if (identical(s, _nearRight) || identical(s, _farRight)) return Maneuver.right;
    if (identical(s, _innerThrough) || identical(s, _outerThrough)) {
      return Maneuver.straight;
    }
    return null;
  }

  /// The inner-lane LEFT-turn movement per approach — kept by identity so the
  /// NPC signal logic can tell a left-turner (which must yield to oncoming
  /// through) from a through/right car.
  late final Map<_Heading, Spline> _npcLeftSpline = {
    for (final h in _Heading.values)
      h: Spline(_movement(h, _innerOff, Maneuver.left)),
  };

  /// Arc-length along each left-turn spline to the **bend** — where the turner
  /// waits, nosed into the curve, yielding to oncoming. It's the point ON the arc
  /// nearest the box centre (the apex, where the car is angled into the turn), not
  /// the arc-START (which is still straight, before the curve — waiting there reads
  /// as "stopped across the lanes before the bend"). Nudged a half-car deeper so it
  /// rests clearly on the curve. Arc-length (not a straight gap) because the wait
  /// point is mid-curve, where the path has turned away from the approach heading.
  late final Map<_Heading, double> _npcLeftBendDist = {
    for (final h in _Heading.values)
      h: _npcLeftSpline[h]!.distanceAtNearest(_centre) + kCarLength * 0.5,
  };

  /// NPC LEFT turns are offered on only ONE approach per opposing pair — NORTH
  /// (the player's own approach, so they still see left-turners in their lane) and
  /// EAST (the cross axis). Two OPPOSING left-turners cross head-on through the box
  /// centre and — being speed-only on a fixed spline, no steering — can't slip
  /// around each other the way the (human-steered) player does; the only safe
  /// resolution was a "wait at the line" stagger that kept reading as idiotic
  /// (user: "staying like morons on the stop line"). Offering lefts on
  /// non-opposing approaches removes the conflict BY CONSTRUCTION: south/west never
  /// turn left, and north-left vs east-left are split across the two green phases
  /// (N–S vs E–W) so two box-crossing lefts are never live at once. The old
  /// `_opposingLeftHolds` stagger is deleted with it. The user weighed this against
  /// rerouting the arcs to pass left-to-left and chose it — that reroute is
  /// geometrically impossible here anyway (the inner approach lane of one direction
  /// and the inner exit lane of its opposite cross at a fixed point regardless of
  /// turn radius — verified by an all-relative-positions OBB sweep).
  static bool _npcLeftAllowed(_Heading h) =>
      h == _Heading.north || h == _Heading.east;

  /// NPC lanes — maneuver-INDEPENDENT (cross/through traffic is unrelated to the
  /// player's commanded turn). 8 groups: each approach has an inner lane (straight,
  /// plus LEFT where [_npcLeftAllowed]) and an outer lane (straight or right). Group
  /// index `k*2 + lane` → heading `_Heading.values[k]`, lane 0 = inner, 1 = outer.
  @override
  late final List<List<Spline>> npcLanes = [
    for (final h in _Heading.values) ...[
      [
        Spline(_movement(h, _innerOff, Maneuver.straight)),
        if (_npcLeftAllowed(h)) _npcLeftSpline[h]!,
      ],
      [
        for (final m in const [Maneuver.straight, Maneuver.right])
          Spline(_movement(h, _outerOff, m)), // outer: straight or right
      ],
    ],
  ];

  static _Heading _opposite(_Heading h) => _rightTurn(_rightTurn(h));

  bool _isLeftTurnNpc(NpcCar npc, _Heading heading) =>
      npc.spline != null && identical(npc.spline, _npcLeftSpline[heading]);

  /// Test hook: the inner-lane LEFT-turn spline + its NPC `laneIndex` for the
  /// SOUTH approach — the approach whose oncoming-through is the northbound player.
  /// Lets a test place a left-turner at the bend and check it yields to the player,
  /// without leaking `_Heading`.
  @visibleForTesting
  (Spline, int) get debugSouthLeftTurner =>
      (_npcLeftSpline[_Heading.south]!, _Heading.values.indexOf(_Heading.south) * 2);

  /// Pure: should a left-turning NPC commit through the box? Like a real left-
  /// turner it pulls INTO the junction to the **bend** (the arc apex, nosed into
  /// the curve) and yields there to oncoming-through, not back at the stop line:
  ///  - past the bend → mid-turn, always finish (never re-hold / freeze);
  ///  - short of the line → enter the box only on green and only into a clear gap
  ///    (on red it holds at the line — the caller's stop target does that);
  ///  - in the box (entered on green) → wait at the bend for oncoming, then complete.
  /// The last branch is also phase-end clearance: at yellow→red the oncoming brakes
  /// ([oncomingBlocks] lifts) and the waiting turner completes during all-red — no
  /// separate logic, no yellow-instant dart. Static + pure → unit-tested.
  @visibleForTesting
  static bool npcLeftCommits({
    required bool green,
    required double gapToLine,
    required double gapToBend,
    required bool oncomingBlocks,
  }) {
    if (gapToBend <= 0) return true; // past the bend — finish the turn
    if (gapToLine > 0) return green && !oncomingBlocks; // approach: enter on a green gap
    return !oncomingBlocks; // at the bend — hold for oncoming, then complete
  }

  /// Is oncoming-through traffic close enough that a left turn from [heading]
  /// would cut it off? Conservative — ANY moving opposing-through (an NPC, or the
  /// player when they're the opposing through) in the approach/box holds the
  /// turn. A turner held at the bend can't cross until this is clear, so it never
  /// T-bones; and it lifts when the oncoming stops, so it never gridlocks.
  bool _oncomingThroughBlocks(_Heading heading, NpcCar turner,
      List<NpcCar> allNpcs, PlayerCar playerCar) {
    final opp = _opposite(heading);
    for (final other in allNpcs) {
      if (identical(other, turner) || other.spline == null) continue;
      if (other.laneIndex < 0 || other.laneIndex >= npcLanes.length) continue;
      if (_headingOfLane(other.laneIndex) != opp) continue;
      if (!_movementStraight(other.spline!)) continue; // oncoming THROUGH only
      final oLocal = worldToLocal(other.position);
      final z = _zoneOf(opp, oLocal);
      if (z != _Zone.approaching && z != _Zone.inBox) continue;
      if (other.speed <= kStopSpeedThreshold) continue; // stopped doesn't block
      // Once it's past the centre it has cleared the turn's crossing point — it no
      // longer blocks (release the turner now, not when it finally leaves the box).
      if (z == _Zone.inBox && _passedCentre(opp, oLocal)) continue;
      return true;
    }
    // The player heads north (through), so it is the oncoming through for a
    // turner whose opposite approach is north — i.e. a south-heading left-turner.
    if (opp == _Heading.north) {
      final pLocal = worldToLocal(playerCar.position);
      final pz = _zoneOf(_Heading.north, pLocal);
      if ((pz == _Zone.approaching || pz == _Zone.inBox) &&
          playerCar.speed > kStopSpeedThreshold) {
        // A straight-through player past the centre has cleared the crossing; a
        // TURNING player stays a block (their left is head-on with this turn, so
        // releasing on "past centre" — which the curve invalidates — could T-bone).
        final cleared = pz == _Zone.inBox &&
            _committedExit == Maneuver.straight &&
            _passedCentre(_Heading.north, pLocal);
        if (!cleared) return true;
      }
    }
    return false;
  }

  /// Has a STRAIGHT car with [heading] passed the box centre in its travel
  /// direction? The left-turn exit lanes sit `_innerOff` short of centre on the
  /// side the oncoming enters from, so past centre the car has already cleared any
  /// left-turn's crossing point (with that `_innerOff` margin + the turner's own
  /// pull-away time). Only valid for a straight mover — a turning car's curve
  /// breaks the "centre ⇒ past the crossing" relation.
  bool _passedCentre(_Heading heading, Vector2 localPos) {
    switch (heading) {
      case _Heading.north:
        return localPos.y < _cy; // moving up (−y)
      case _Heading.south:
        return localPos.y > _cy; // moving down (+y)
      case _Heading.east:
        return localPos.x > _cx; // moving right (+x)
      case _Heading.west:
        return localPos.x < _cx; // moving left (−x)
    }
  }


  @override
  late final List<Spline> npcPaths = [for (final lane in npcLanes) ...lane];

  _Heading _headingOfLane(int laneIndex) => _Heading.values[laneIndex ~/ 2];

  @override
  Vector2 get entryAnchor => Vector2(_cx + _innerOff, _h); // inner south

  @override
  Vector2 get exitAnchor => switch (_committedExit) {
        Maneuver.straight => Vector2(_cx + _innerOff, 0),
        Maneuver.left => Vector2(0, _cy - _innerOff),
        Maneuver.right => Vector2(_w, _cy + _innerOff),
      };

  @override
  Vector2 get exitDirection => switch (_committedExit) {
        Maneuver.straight => Vector2(0, -1),
        Maneuver.left => Vector2(-1, 0),
        Maneuver.right => Vector2(1, 0),
      };

  // ---------------------------------------------------------------------------
  // Late-bind the commanded maneuver: a random pick from the config's pool.
  // ---------------------------------------------------------------------------

  @override
  void bindPlayerEntry(Vector2 playerCentreWorld) {
    if (_maneuverBound) return;
    _maneuverBound = true;
    // Command a uniformly random maneuver from the active config's pool. The
    // entry lane forces nothing: a lane change is the task only when the dice
    // don't match the lane you came in on — fair, and how often it happens varies
    // by config. The player paths are maneuver-independent (both lanes straight;
    // the turn is chosen at the box with the wheel), so nothing to rebuild here.
    final pool = _config.commandable().toList(growable: false);
    _maneuver = pool[_rng.nextInt(pool.length)];
  }

  // ---------------------------------------------------------------------------
  // Zones / gaps (centre-based, mirrors IntersectionTile with _half=160).
  // ---------------------------------------------------------------------------

  _Zone _zoneOf(_Heading heading, Vector2 localPos) {
    final dx = localPos.x - _cx;
    final dy = localPos.y - _cy;
    if (dx.abs() <= _half && dy.abs() <= _half) return _Zone.inBox;
    switch (heading) {
      case _Heading.north:
        if (dy > _half && dy < _half + _approachDistance) return _Zone.approaching;
        if (dy < -_half) return _Zone.past;
        return _Zone.far;
      case _Heading.south:
        if (dy < -_half && dy > -(_half + _approachDistance)) return _Zone.approaching;
        if (dy > _half) return _Zone.past;
        return _Zone.far;
      case _Heading.east:
        if (dx < -_half && dx > -(_half + _approachDistance)) return _Zone.approaching;
        if (dx > _half) return _Zone.past;
        return _Zone.far;
      case _Heading.west:
        if (dx > _half && dx < _half + _approachDistance) return _Zone.approaching;
        if (dx < -_half) return _Zone.past;
        return _Zone.far;
    }
  }

  double _gapToStopLine(_Heading heading, Vector2 localPos) {
    switch (heading) {
      case _Heading.north:
        return localPos.y - (_cy + _stopLineFromCentre);
      case _Heading.south:
        return (_cy - _stopLineFromCentre) - localPos.y;
      case _Heading.east:
        return (_cx - _stopLineFromCentre) - localPos.x;
      case _Heading.west:
        return localPos.x - (_cx + _stopLineFromCentre);
    }
  }

  double _gapToBoxFarEdge(_Heading heading, Vector2 localPos) {
    switch (heading) {
      case _Heading.north:
        return localPos.y - (_cy - _half);
      case _Heading.south:
        return (_cy + _half) - localPos.y;
      case _Heading.east:
        return (_cx + _half) - localPos.x;
      case _Heading.west:
        return localPos.x - (_cx - _half);
    }
  }

  final Map<Spline, bool> _straightCache = {};
  bool _movementStraight(Spline path) => _straightCache.putIfAbsent(
      path, () => path.tangent(0.0).dot(path.tangent(1.0)) > 0.85);

  // Steering is ALWAYS on across this tile (no box-off override): the box is purely
  // a rules region now. The two lane spines merge by offset the whole height; the
  // turns hang on them as taps ([playerBranches], resolved per-frame by TileManager).
  // Through the box the player follows the chosen turn (or the straight spine) with the
  // ordinary kIntentionLean lean — there is no swerve-cheat to suppress.

  // ---------------------------------------------------------------------------
  // Per-frame sensor + grading wiring.
  // ---------------------------------------------------------------------------

  @override
  void updateNpcSensors(
    double dt,
    PlayerCar playerCar,
    List<NpcCar> allNpcs,
    List<Pedestrian> pedestrians, {
    bool gradePlayer = true,
  }) {
    super.updateNpcSensors(dt, playerCar, allNpcs, pedestrians);
    if (kDebugMode && DebugState.showDebug) _debugPeds = pedestrians;

    // --- NPC GOVERNANCE (runs for trailing tiles too) -----------------------
    // A pedestrian probe per NPC along its own spline, folded into the signal
    // apply. This MUST keep running once the player has driven past the junction
    // (trailing): the cross-traffic is deliberately kept driving, so without
    // governance it would cruise on the brain's default right-of-way straight
    // through pedestrians and stopped cars (the "ghost" bug).
    final pedStopById = <Object, double?>{
      for (final npc in npcs)
        if (npc.spline != null)
          npc: _pedStopOnPath(npc.spline!, npc.distanceTravelled, pedestrians),
    };
    _applySignalToNpcs(pedStopById, allNpcs, playerCar);

    // --- PLAYER GRADING (active tile only) ----------------------------------
    // Everything below judges the player or tracks its exit. Skip it on a tile
    // the player has left, or a passed junction would fault a far-away player
    // and re-place downstream tiles off a stale exit.
    if (!gradePlayer) return;

    // Track the committed exit from the branch the player is on. With the discrete
    // fork node the player only becomes a branch ONCE — when they cross the box
    // mouth and pick — so this fires a single time (no per-frame thrash), re-placing
    // the downstream tile against the now-final exit while it's a full tile ahead.
    final exitM = _exitManeuver(playerCar.spline);
    if (exitM != null && exitM != _committedExit) {
      _committedExit = exitM;
      exitChanged = true;
    }

    final playerSpline = playerCar.spline;
    final playerPedStop = playerSpline != null
        ? _pedStopOnPath(playerSpline, playerCar.distanceTravelled, pedestrians)
        : null;
    _pedBlockingPlayer = playerPedStop != null;

    _signalPlayerWait(playerCar);
    _updateReactionSuppression(playerCar);
    _checkPlayerApproach(playerCar); // red-light + safe-clear
    if (_phaseOf(_Heading.north) == SignalPhase.green) {
      _checkLeftYieldToOncoming(playerCar);
    }
    _checkPedestrianGiveWay(playerCar, pedestrians);
    _checkBlockedIntersection(dt, playerCar, allNpcs);
  }

  void _applySignalToNpcs(Map<Object, double?> pedStopById, List<NpcCar> allNpcs,
      PlayerCar playerCar) {
    for (final npc in npcs) {
      npc.setHeadlightFlash(false);
      if (npc.laneIndex < 0 ||
          npc.laneIndex >= npcLanes.length ||
          npc.spline == null) {
        npc.brain.intersectionRuleActive = false;
        npc.brain.hasRightOfWay = true;
        npc.brain.stopTargetDistance = null;
        npc.brain.speedCap = null;
        continue;
      }
      final heading = _headingOfLane(npc.laneIndex);
      final localPos = worldToLocal(npc.position);
      final z = _zoneOf(heading, localPos);
      final pedStop = pedStopById[npc];
      final isLeft = _isLeftTurnNpc(npc, heading);
      // In-box LEFT-turners stay under the yield logic below — they pull in and wait
      // at the BEND (arc-start, inside the box) yielding to oncoming, so they must
      // NOT get the blanket in-box right-of-way that through/right traffic gets. A
      // left-turner that has already cleared (z == past) drops through to ROW too.
      if (z != _Zone.approaching && !(isLeft && z == _Zone.inBox)) {
        npc.brain.intersectionRuleActive = false;
        npc.brain.hasRightOfWay = true;
        npc.brain.stopTargetDistance = pedStop;
        final overCrossing =
            _crossingAhead(npc.spline!, npc.distanceTravelled, kCarLength * 2);
        npc.brain.speedCap =
            (z == _Zone.inBox || overCrossing) ? kNpcTurnSpeed : null;
        continue;
      }

      final green = _phaseOf(heading) == SignalPhase.green;
      final gap = _gapToStopLine(heading, localPos);
      // A left-turner yields from the BEND: it pulls INTO the junction and waits
      // nosed into the curve (the arc apex), yielding to straight traffic, then
      // crosses when clear — like real life, NOT back at the stop line and NOT
      // stopped straight before the curve. `gapToBend` is the remaining ARC-LENGTH
      // to that point (it's mid-curve, so a straight-line gap won't do). Through and
      // right cars just use the line gap.
      final gapToBend =
          isLeft ? (_npcLeftBendDist[heading]! - npc.distanceTravelled) : gap;
      // Is oncoming-through actually blocking (green or not)? Keying on this rather
      // than `green` makes phase-end fall out for free: at yellow→red the oncoming
      // brakes, this lifts, and the waiting turner completes during all-red.
      final oncomingBlocks = isLeft &&
          gapToBend > 0 &&
          _oncomingThroughBlocks(heading, npc, allNpcs, playerCar);
      // No opposing-left stagger: NPC lefts are offered only on non-opposing
      // approaches ([npcLanes]), so two box-crossing lefts are never live at once.
      // A left-turner's only hold is the BEND yield to oncoming-through.
      final committed = isLeft
          ? npcLeftCommits(
              green: green,
              gapToLine: gap,
              gapToBend: gapToBend,
              oncomingBlocks: oncomingBlocks)
          : (green || gap <= 0);
      final boxBlocked = green &&
          gap > 0 &&
          cannotClearBox(_gapToBoxFarEdge(heading, localPos),
              _stoppedLeadGap(npc, allNpcs, playerCar));
      final goNow = committed && !boxBlocked;
      npc.brain.intersectionRuleActive = !goNow;
      npc.brain.hasRightOfWay = goNow;
      npc.brain.stopTargetDistance = _nearerStop(
          _nearerStop(signalStopTarget(green, gap, pedStop),
              boxBlocked ? gap : null),
          oncomingBlocks ? gapToBend : null); // yielding turner holds at the bend
      // Gentleness: a left-turner eases to its wait at a COMFORTABLE decel (110),
      // starting early — it rolls up to the bend instead of braking like a race car.
      // Yielding → ease to a halt at the bend; clear → pace to turn speed so the turn
      // still flows. The hard stopTargetDistance stays as the overshoot backstop.
      npc.brain.speedCap =
          isLeft ? leftTurnApproachCap(gapToBend, yielding: oncomingBlocks) : null;
    }
  }

  /// Hold-at-line target for a signalised approach, folded with any pedestrian
  /// stop. Green never stops for the light; a car at/past the line commits and
  /// clears (no dead stop in the junction mouth). Pure → unit-tested.
  @visibleForTesting
  static double? signalStopTarget(bool green, double gapToLine, double? pedStop) =>
      _nearerStop((green || gapToLine <= 0) ? null : gapToLine, pedStop);

  /// Comfort-decel speed cap for a left-turner approaching its wait point, so it
  /// eases in gently instead of braking hard at the last moment. [yielding] → ease
  /// all the way to a halt at [gapToStop] (the bend, or the line when waiting for an
  /// opposing left); otherwise pace down toward (and floor at) turn speed so a clear
  /// turn keeps flowing. Same setback as `NpcBrain._applyStopTarget` so the gentle
  /// halt lands where the hard backstop would. Pure → unit-tested.
  @visibleForTesting
  static double leftTurnApproachCap(double gapToStop, {required bool yielding}) {
    final brakeDist = gapToStop - kCarLength * 0.5 - kStopLineSetback;
    if (yielding) {
      return brakeDist <= 1.0
          ? 0.0
          : math.sqrt(2 * kComfortBrakeDecel * brakeDist);
    }
    return math.sqrt(kNpcTurnSpeed * kNpcTurnSpeed +
        2 * kComfortBrakeDecel * math.max(0.0, brakeDist));
  }

  // ---------------------------------------------------------------------------
  // Player wait / road-block exemption.
  // ---------------------------------------------------------------------------
  bool _playerMustWait = false;
  bool _pedBlockingPlayer = false;
  bool _otherCarInBox = false;

  @override
  bool get playerMustWait => _playerMustWait;

  /// Suppress the generic cut-off "!" detector only near/inside the box — where a
  /// waiting player draws queueing cars that would false-positive. On the open
  /// approach it stays ON so a genuine lane-change cut-off still reads. Cached
  /// each frame (the detector polls it via [suppressDriverReactions]).
  bool _suppressReactions = false;

  @override
  bool get suppressDriverReactions => _suppressReactions;

  void _updateReactionSuppression(PlayerCar playerCar) {
    final pl = worldToLocal(playerCar.position);
    final pz = _zoneOf(_Heading.north, pl);
    _suppressReactions = pz != _Zone.approaching ||
        _gapToStopLine(_Heading.north, pl) < kCarLength * 2;
  }

  void _signalPlayerWait(PlayerCar playerCar) {
    final playerLocal = worldToLocal(playerCar.position);
    if (kDebugMode && DebugState.showDebug) _debugPlayerLocal = playerLocal;
    final pZone = _zoneOf(_Heading.north, playerLocal);
    final green = _phaseOf(_Heading.north) == SignalPhase.green;

    _otherCarInBox = npcs.any((n) =>
        n.laneIndex >= 0 &&
        n.laneIndex < npcLanes.length &&
        n.spline != null &&
        _zoneOf(_headingOfLane(n.laneIndex), worldToLocal(n.position)) ==
            _Zone.inBox);

    final oncomingPresent = _maneuver == Maneuver.left &&
        npcs.any((n) {
          if (n.spline == null) return false;
          if (_headingOfLane(n.laneIndex) != _Heading.south) return false;
          final z = _zoneOf(_Heading.south, worldToLocal(n.position));
          return z == _Zone.approaching || z == _Zone.inBox;
        });

    _playerMustWait = (pZone == _Zone.approaching && !green) ||
        (pZone == _Zone.inBox && _otherCarInBox) ||
        ((pZone == _Zone.approaching || pZone == _Zone.inBox) && oncomingPresent) ||
        _pedBlockingPlayer;
  }

  // ---------------------------------------------------------------------------
  // Left-turn fail-to-yield to oncoming through-traffic (both oncoming lanes).
  // ---------------------------------------------------------------------------
  bool _yieldViolationFired = false;
  final List<NpcCar> _playerYieldTargets = [];

  void _checkLeftYieldToOncoming(PlayerCar playerCar) {
    if (_maneuver != Maneuver.left || _yieldViolationFired) return;
    if (playerCar.speed <= kStopSpeedThreshold) return;

    for (final npc in npcs) {
      if (npc.spline == null) continue;
      if (_headingOfLane(npc.laneIndex) != _Heading.south) continue; // oncoming
      if (!_movementStraight(npc.spline!)) continue; // through-traffic
      final z = _zoneOf(_Heading.south, worldToLocal(npc.position));
      if (z != _Zone.approaching && z != _Zone.inBox) continue;
      final gap = _oncomingGapToPlayer(npc, playerCar);
      if (gap == null) continue;
      if (!leftTurnFailsToYield(npc.speed, gap)) continue;

      _yieldViolationFired = true;
      GameBus.instance.emit(YieldViolationEvent(speedAtLine: playerCar.speed));
      _playerYieldTargets
        ..clear()
        ..add(npc);
      _markYieldTargets(playerCar);
      return;
    }
  }

  double? _oncomingGapToPlayer(NpcCar npc, PlayerCar playerCar) {
    final fwd = Vector2(math.cos(npc.angle), math.sin(npc.angle));
    final delta = playerCar.position - npc.position;
    final ahead = delta.dot(fwd);
    if (ahead < kCarLength * 0.5) return null;
    final lateral = (delta - fwd * ahead).length;
    if (lateral > kCarWidth * 1.8) return null;
    return (ahead - kCarLength).clamp(0.0, double.infinity);
  }

  @visibleForTesting
  static bool leftTurnCutsOffOncoming(double oncomingSpeed, double gapToPlayer) {
    if (oncomingSpeed < kReactMinSpeed) return false;
    return DriverReactionDetector.isForcedHardBrake(oncomingSpeed, gapToPlayer);
  }

  /// Pure: did a left turn fail to yield to this oncoming-through car? Two ways,
  /// OR'd: (a) a FAST oncoming forced into a hard brake ([leftTurnCutsOffOncoming]);
  /// (b) a clear CUT-OFF — the player took the crossing within a car-length-ish of
  /// an oncoming car that is still MOVING. (b) is what (a) misses when the oncoming
  /// is crawling (e.g. stuck behind an opposing left-turner): its speed/braking is
  /// contaminated by the queue, so the signal is the player's *position* in front of
  /// it, not how hard it braked. A STOPPED car (`speed ≤ kStopSpeedThreshold`) is
  /// never "cut off" — that carve-out keeps a legal turn in front of halted traffic
  /// clean; a FAR car never lands the player a car-length ahead. Static + pure.
  @visibleForTesting
  static bool leftTurnFailsToYield(double oncomingSpeed, double gapToPlayer) {
    if (oncomingSpeed <= kStopSpeedThreshold) return false; // not going → not cut off
    if (leftTurnCutsOffOncoming(oncomingSpeed, gapToPlayer)) return true; // fast: forced brake
    return gapToPlayer < kCarLength * 1.5; // moving + close: took the crossing in front
  }

  // ---------------------------------------------------------------------------
  // "Don't block the box".
  // ---------------------------------------------------------------------------
  static const double _blockBoxGraceSeconds = 1.5;
  double _blockedBoxTimer = 0.0;
  bool _blockedBoxFired = false;

  bool _playerOverlapsBox(PlayerCar playerCar) {
    final fwd = Vector2(math.cos(playerCar.angle), math.sin(playerCar.angle));
    for (final s in const [kCarLength / 2, 0.0, -kCarLength / 2]) {
      final p = worldToLocal(playerCar.position + fwd * s);
      if ((p.x - _cx).abs() <= _half && (p.y - _cy).abs() <= _half) return true;
    }
    return false;
  }

  bool _playerExitBlocked(PlayerCar playerCar, List<NpcCar> allNpcs) {
    final fwd = Vector2(math.cos(playerCar.angle), math.sin(playerCar.angle));
    for (final npc in allNpcs) {
      if (npc.speed > kStopSpeedThreshold) continue;
      final delta = npc.position - playerCar.position;
      final ahead = delta.dot(fwd);
      if (ahead <= 0 || ahead > kCarLength * 2.0) continue;
      final lateral = (delta - fwd * ahead).length;
      if (lateral > kCarWidth * 1.5) continue;
      return true;
    }
    return false;
  }

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
      GameBus.instance.emit(BlockedIntersectionEvent());
    }
  }

  @visibleForTesting
  static bool cannotClearBox(double gapToFarEdge, double? stoppedLeadGap) {
    if (stoppedLeadGap == null || gapToFarEdge <= 0) return false;
    return stoppedLeadGap < gapToFarEdge + kCarLength + kNpcStandingGap;
  }

  double? _stoppedLeadGap(NpcCar npc, List<NpcCar> allNpcs, PlayerCar playerCar) {
    final fwd = Vector2(math.cos(npc.angle), math.sin(npc.angle));
    double? best;
    void consider(Vector2 pos, double speed) {
      if (speed > kStopSpeedThreshold) return;
      final delta = pos - npc.position;
      final ahead = delta.dot(fwd);
      if (ahead < kCarLength * 0.5) return;
      final lateral = (delta - fwd * ahead).length;
      if (lateral > kCarWidth * 1.8) return;
      final gap = (ahead - kCarLength).clamp(0.0, double.infinity);
      if (best == null || gap < best!) best = gap;
    }

    for (final o in allNpcs) {
      if (!identical(o, npc)) consider(o.position, o.speed);
    }
    consider(playerCar.position, playerCar.speed);
    return best;
  }

  static double? _nearerStop(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

  // ---------------------------------------------------------------------------
  // Player approach state machine: red-light, safe-clear. (Lane-discipline
  // grading is deferred — merge-first already steers you to the correct lane.)
  // ---------------------------------------------------------------------------
  bool _redViolationFired = false;
  bool _gateCrossed = false;
  bool _clearedReported = false;

  // Signal-judgment state (reset each approach).
  bool _stoppedInApproach = false; // came to a full stop before the gate
  bool _couldStopAtYellow = false; // snapshot at the yellow rising edge
  bool _stopLineFaultFired = false;
  SignalPhase? _prevPlayerPhase; // for yellow rising-edge detection

  /// How far the nose must be past the stop line (over the line / into the
  /// crosswalk) before a stopped car on red earns the stop-line fault.
  static const double _stopLineNoseMargin = 6.0;

  double get _gateLineY => _cy + _half; // box near edge on the south approach

  bool _playerExitedBox(Vector2 local) {
    final dx = local.x - _cx;
    final dy = local.y - _cy;
    final outside = dx.abs() > _half || dy.abs() > _half;
    final onEntrySide = dy > _half;
    return outside && !onEntrySide;
  }

  void _checkPlayerApproach(PlayerCar playerCar) {
    final local = worldToLocal(playerCar.position);
    final localY = local.y;

    if (localY > _cy + _stopLineFromCentre + _approachDistance) {
      _redViolationFired = false;
      _yieldViolationFired = false;
      _gateCrossed = false;
      _clearedReported = false;
      _committedExit = Maneuver.straight;
      _stoppedInApproach = false;
      _couldStopAtYellow = false;
      _stopLineFaultFired = false;
      _prevPlayerPhase = null;
      return;
    }

    if (_playerExitedBox(local)) {
      if (!_clearedReported) {
        _clearedReported = true;
        // Grade lane discipline from the exit spline the player committed to
        // (synchronous). A fault withholds the pass; the emitted event fails and
        // records the run on the next tick (the bus is async, so we can't call
        // onSafelyCleared this frame and still let the fault win).
        if (!_gradeLaneDiscipline(playerCar)) {
          scenario.onSafelyCleared();
          if (scenario.result.status == ScenarioStatus.passed) {
            GameBus.instance.emit(RulePassedEvent());
          }
        }
      }
      return;
    }

    // Signal compliance on the approach. Lane discipline (wrong lane / missed
    // turn / wrong exit lane) is graded on the way OUT, from the exit spline the
    // player left on — see [_gradeLaneDiscipline], called above on clear.
    _checkSignalJudgment(playerCar, localY);
  }

  /// Yellow dilemma, stop-line discipline, and the red / right-on-red gate
  /// verdict — the signal-compliance grading. Thin glue over the pure
  /// [signalGateVerdict] / [couldStopForYellow].
  void _checkSignalJudgment(PlayerCar playerCar, double localY) {
    final phase = _phaseOf(_Heading.north);
    final fwd = Vector2(math.cos(playerCar.angle), math.sin(playerCar.angle));
    final noseLocal = worldToLocal(playerCar.position + fwd * (kCarLength / 2));
    final noseGap = _gapToStopLine(_Heading.north, noseLocal);

    // A full stop anywhere on the approach (for the right-on-red "stopped first").
    if (playerCar.speed <= kStopSpeedThreshold) _stoppedInApproach = true;

    // Yellow rising edge → snapshot whether the player could comfortably stop.
    if (phase == SignalPhase.yellow && _prevPlayerPhase != SignalPhase.yellow) {
      _couldStopAtYellow = couldStopForYellow(noseGap, playerCar.speed);
    } else if (phase != SignalPhase.yellow) {
      _couldStopAtYellow = false; // stale once the light leaves yellow
    }
    _prevPlayerPhase = phase;

    // Stop-line discipline: stopped, on red, nose past the line, not yet in the
    // box (the narrow [stop line, gate] crosswalk zone — distinct from the red
    // gate fault, which is for crossing INTO the box).
    if (!_stopLineFaultFired &&
        phase == SignalPhase.red &&
        playerCar.speed <= kStopSpeedThreshold &&
        noseGap < -_stopLineNoseMargin &&
        localY > _gateLineY) {
      _stopLineFaultFired = true;
      GameBus.instance.emit(StopLineViolationEvent());
    }

    // Gate crossing → red / right-on-red / yellow verdict (once per approach).
    if (!_gateCrossed && localY <= _gateLineY) {
      _gateCrossed = true;
      switch (signalGateVerdict(
        phase: phase,
        commanded: _maneuver,
        stoppedFirst: _stoppedInApproach,
        couldStopAtYellow: _couldStopAtYellow,
      )) {
        case SignalGateFault.ranRed:
          if (!_redViolationFired) {
            _redViolationFired = true;
            GameBus.instance.emit(RedLightViolationEvent());
          }
        case SignalGateFault.ranYellow:
          GameBus.instance.emit(YellowRunEvent());
        case null:
          // Green gate: gunning it while a late straggler is still clearing the
          // box (cross traffic that didn't make the all-red) is a fault.
          if (phase == SignalPhase.green && _crossTrafficInBox()) {
            GameBus.instance.emit(GunGreenEvent());
          }
      }
    }
  }

  /// Cross traffic (an E/W NPC) still occupying the box — for catching a green
  /// gunned before a late straggler has finished clearing the junction.
  bool _crossTrafficInBox() => npcs.any((n) {
        if (n.laneIndex < 0 ||
            n.laneIndex >= npcLanes.length ||
            n.spline == null) {
          return false;
        }
        final h = _headingOfLane(n.laneIndex);
        if (h != _Heading.east && h != _Heading.west) return false;
        return _zoneOf(h, worldToLocal(n.position)) == _Zone.inBox;
      });

  /// Pure: which gate fault crossing the box against [phase] earns (null =
  /// clean). Green is clean; a right-on-red is legal AFTER a full stop
  /// ([stoppedFirst]); anything else on red runs it; a yellow you could have
  /// stopped for ([couldStopAtYellow]) is the dilemma-zone fault. Static + pure.
  /// (v1: right-on-red requires only the stop, not yet yielding to cross/peds.)
  @visibleForTesting
  static SignalGateFault? signalGateVerdict({
    required SignalPhase phase,
    required Maneuver commanded,
    required bool stoppedFirst,
    required bool couldStopAtYellow,
  }) {
    switch (phase) {
      case SignalPhase.green:
        return null;
      case SignalPhase.yellow:
        return couldStopAtYellow ? SignalGateFault.ranYellow : null;
      case SignalPhase.red:
        // A right-on-red is legal after a full stop; anything else runs the red.
        if (commanded == Maneuver.right && stoppedFirst) return null;
        return SignalGateFault.ranRed;
    }
  }

  /// Pure: at yellow onset, could the player stop COMFORTABLY before the line —
  /// reaction creep + v²/2a at a gentle decel ([kComfortBrakeDecel]). If so,
  /// proceeding through is the dilemma-zone fault. Static + pure → unit-tested.
  @visibleForTesting
  static bool couldStopForYellow(double gapToLine, double speed) {
    if (gapToLine <= 0) return false; // already at/over the line — commit
    final stopDist = speed * kYellowReactionSeconds +
        (speed * speed) / (2 * kComfortBrakeDecel);
    return gapToLine >= stopDist;
  }

  /// Grades lane discipline at box clear, reading the exit spline the player
  /// committed to. The approach lane is implied by that spline (left branches
  /// hang only off the inner spine, right only off the outer; a through spine
  /// keeps its lane), so an in-box correction — allowed — is judged by where the
  /// player actually left from. Emits at most one fault and returns whether one
  /// fired (so the caller withholds the pass). The three are mutually exclusive
  /// and ordered: wrong LANE → wrong MANEUVER (right lane, didn't follow it) →
  /// wrong EXIT lane (right move, far lane instead of nearest).
  bool _gradeLaneDiscipline(PlayerCar playerCar) {
    final s = playerCar.spline;
    final did = _exitManeuver(s);
    if (did == null) return false; // not on one of our splines (handed off)
    final inner = identical(s, _innerThrough) ||
        identical(s, _nearLeft) ||
        identical(s, _farLeft);
    final farExit = identical(s, _farLeft) || identical(s, _farRight);

    switch (laneVerdict(
        config: _config,
        inner: inner,
        did: did,
        commanded: _maneuver,
        farExit: farExit)) {
      case LaneFault.missedTurn:
        GameBus.instance.emit(MissedTurnEvent());
      case LaneFault.wrongLane:
        GameBus.instance.emit(WrongLaneEvent());
      case LaneFault.wrongExitLane:
        GameBus.instance.emit(WrongExitLaneEvent());
      case null:
        return false;
    }
    return true;
  }

  /// Pure lane-discipline verdict from the exit facts, against the active
  /// [config]: the lane the player left from ([inner]?), the maneuver they
  /// actually [did], the [commanded] one, and whether they took the far exit
  /// lane ([farExit]). Null = clean. Ordered and mutually exclusive (see
  /// [LaneFault]). Static + pure → unit-tested.
  @visibleForTesting
  static LaneFault? laneVerdict({
    required LaneConfig config,
    required bool inner,
    required Maneuver did,
    required Maneuver commanded,
    required bool farExit,
  }) {
    // Missing the turn (ending up somewhere other than the instruction) is the
    // headline error — reported ahead of any lane fault, so "skipped the task and
    // went elsewhere" reads as a missed turn, not a lane technicality. A wrong
    // lane is then only a RIGHT move done from the wrong lane (e.g. straight from
    // a turn-only lane).
    if (did != commanded) return LaneFault.missedTurn;
    if (!config.allows(isInner: inner, m: commanded)) return LaneFault.wrongLane;
    if (farExit) return LaneFault.wrongExitLane;
    return null;
  }


  // ---------------------------------------------------------------------------
  // Pedestrian crossings (urban): probe, give-way fault, signal hold.
  // ---------------------------------------------------------------------------
  static const double _zebraEnterMargin = 12.0;
  static const double _zebraBandMargin = _crosswalkHalf + 8.0;

  /// US "half-rule" DANGER ZONE: how close (laterally along the crossing) a ped
  /// must be to a vehicle's path before the vehicle yields to one merely walking
  /// TOWARD it. ~your-half-plus-a-lane (1.5 lanes). A ped still well over on the
  /// FAR half of the wide 2-lane crossing is beyond this, so you don't sit there
  /// for someone two lanes away — an examiner doesn't expect it (you yield to a
  /// ped in your half, or one close enough to your half to be in danger). A ped
  /// right at the path still stops you regardless of direction (the
  /// [kPedYieldLateral] term). One knob: lower it to pass closer. The 1-lane tile
  /// is its own file and unchanged — its narrow crossing is all within a lane.
  static const double _pedDangerZone = kLaneWidth * 1.5; // 120

  int _zebraIndexOf(Vector2 p) {
    final dx = p.x - _cx, dy = p.y - _cy;
    if (dx.abs() <= _half + _zebraEnterMargin) {
      if ((dy - _crosswalkOffset).abs() <= _zebraBandMargin) return 0; // south
      if ((dy + _crosswalkOffset).abs() <= _zebraBandMargin) return 1; // north
    }
    if (dy.abs() <= _half + _zebraEnterMargin) {
      if ((dx + _crosswalkOffset).abs() <= _zebraBandMargin) return 2; // west
      if ((dx - _crosswalkOffset).abs() <= _zebraBandMargin) return 3; // east
    }
    return -1;
  }

  bool _pedOnZebra(Vector2 p) => _zebraIndexOf(p) >= 0;

  /// Test seam: which crossing band a tile-local point falls in (−1 = none).
  /// Lets a test prove perpendicular crossings' bands don't overlap at the box
  /// corners (the false-attribution bug that false-tripped yields/faults).
  @visibleForTesting
  int zebraBandAt(Vector2 localPoint) => _zebraIndexOf(localPoint);

  /// Test seam: the pedestrian stop distance along [sp] (null = clear). Lets a
  /// test check the half-rule danger zone — a ped on the far half doesn't stop you.
  @visibleForTesting
  double? pedStopAlong(Spline sp, double travelled, List<Pedestrian> peds) =>
      _pedStopOnPath(sp, travelled, peds);

  double? _pedStopOnPath(Spline sp, double travelled, List<Pedestrian> pedestrians) {
    if (pedestrians.isEmpty) return null;
    final total = sp.totalLength;
    if (total <= 0) return null;
    // Matching a ped's band to the path's band (below) is only unambiguous while
    // no two perpendicular crossings' detection bands overlap — i.e. a band's
    // near edge clears the box-corner span. Otherwise a corner-stroller is
    // mis-attributed to the cross-street's crossing and false-trips this stop /
    // the player's give-way fault. See [_crosswalkOffset].
    assert(
        _crosswalkOffset - _zebraBandMargin > _half + _zebraEnterMargin,
        "crosswalk offset too small: perpendicular crossings' bands overlap at "
        'the box corners — corner-strollers false-trip yields/faults.');

    final zebraPeds = <({Vector2 pos, Vector2 fwd, int band})>[];
    for (final ped in pedestrians) {
      final local = worldToLocal(ped.position);
      final band = _zebraIndexOf(local);
      if (band < 0) continue;
      zebraPeds.add((
        pos: local,
        fwd: directionToLocal(Vector2(math.cos(ped.angle), math.sin(ped.angle))),
        band: band,
      ));
    }
    if (zebraPeds.isEmpty) return null;

    const conflict = kPedYieldLateral;
    const step = 10.0;
    bool committing = _pedOnZebra(sp.evaluate((travelled / total).clamp(0.0, 1.0)));
    double? bandEntry;
    for (double d = step;
        d <= kPedYieldScanDistance && travelled + d <= total;
        d += step) {
      final pt = sp.evaluate(((travelled + d) / total).clamp(0.0, 1.0));
      final ptBand = _zebraIndexOf(pt);
      if (committing) {
        if (ptBand < 0) committing = false;
        continue;
      }
      if (ptBand < 0) {
        bandEntry = null;
        continue;
      }
      bandEntry ??= d;
      for (final p in zebraPeds) {
        if (p.band != ptBand) continue;
        // Half-rule: stop for a ped right at the path ([conflict], any direction),
        // or one within the [_pedDangerZone] walking TOWARD it. A ped still well
        // over on the far half is beyond the zone → don't wait for it.
        final lateral = p.pos.distanceTo(pt);
        if (lateral <= conflict ||
            (lateral <= _pedDangerZone && (pt - p.pos).dot(p.fwd) > 0)) {
          return bandEntry;
        }
      }
    }
    return null;
  }

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

  /// Whether a crossing ped stepping onto zebra [band] must hold for the signal:
  /// bands 0/1 cross the N–S road (gated by N–S phase), 2/3 the E–W road. Holds
  /// while the crossed road is not red (conflicting traffic moving) AND — the
  /// flashing-don't-walk rule — for the last [crossedRoadRedRemaining] tail of an
  /// otherwise-open window: with under [dontStartWindow] left, don't step off the
  /// curb only to get caught mid-box when the light flips. A ped past the near
  /// carriageway edge in its travel direction is committed and never re-held
  /// (the tail-hold sits BEHIND that early-return, so nothing freezes in-lane).
  /// Pure → unit-tested.
  @visibleForTesting
  static bool pedMustHoldForSignal(int band, double alongFromCentre,
      double travelSign, SignalPhase nsPhase, SignalPhase ewPhase,
      {required double crossedRoadRedRemaining,
      double dontStartWindow = kPedDontStartWindow}) {
    if (band < 0) return false;
    final committed = alongFromCentre * travelSign >= -_half;
    if (committed) return false; // off the curb → finish, never re-held
    final crossesNS = band == 0 || band == 1;
    if ((crossesNS ? nsPhase : ewPhase) != SignalPhase.red) {
      return true; // conflicting traffic has the green/yellow
    }
    // Window open but about to close: hold for the next cycle instead of
    // stepping into a crossing the light won't keep clear long enough.
    return crossedRoadRedRemaining < dontStartWindow;
  }

  @override
  bool pedestrianHeldBySignal(Vector2 worldPos, Vector2 worldDir) {
    if (locale != LocaleType.urban) return false;
    final local = worldToLocal(worldPos);
    final localDir = directionToLocal(worldDir);
    final band = _zebraIndexOf(local + localDir * kPedStepProbe);
    if (band < 0) return false;
    final crossesNS = band == 0 || band == 1;
    final along = crossesNS ? local.x - _cx : local.y - _cy;
    final sign = (crossesNS ? localDir.x : localDir.y).sign;
    return pedMustHoldForSignal(
        band, along, sign, _phaseOf(_Heading.north), _phaseOf(_Heading.east),
        crossedRoadRedRemaining:
            _signal.redRemainingFor(northSouth: crossesNS));
  }

  bool _playerOnBand(PlayerCar playerCar, int idx) {
    final fwd = Vector2(math.cos(playerCar.angle), math.sin(playerCar.angle));
    for (final s in const [kCarLength / 2, 0.0, -kCarLength / 2]) {
      if (_zebraIndexOf(worldToLocal(playerCar.position + fwd * s)) == idx) {
        return true;
      }
    }
    return false;
  }

  Pedestrian? _playerCuttingOffPed(PlayerCar playerCar, List<Pedestrian> peds) {
    if (peds.isEmpty) return null;
    for (final ped in peds) {
      final idx = _zebraIndexOf(worldToLocal(ped.position));
      if (idx < 0) continue;
      if (ped.startledByPlayer) return ped;
      if (!_playerOnBand(playerCar, idx)) continue;
      final toPlayer = playerCar.position - ped.position;
      // Same half-rule danger zone as the stop: you only "cut off" a ped you
      // passed CLOSE to (within [_pedDangerZone]) — not one two lanes away on the
      // far half. Without this, relaxing the stop would fault you for legally going.
      if (toPlayer.length > _pedDangerZone) continue;
      final pedFwd = Vector2(math.cos(ped.angle), math.sin(ped.angle));
      if (pedFwd.dot(toPlayer) > 0) return ped;
    }
    return null;
  }

  final Set<Pedestrian> _gaveWayFaulted = {};

  void _checkPedestrianGiveWay(PlayerCar playerCar, List<Pedestrian> peds) {
    _gaveWayFaulted.retainWhere(peds.contains);
    if (playerCar.speed <= kStopSpeedThreshold) return;
    final cutOff = _playerCuttingOffPed(playerCar, peds);
    if (cutOff == null || !_gaveWayFaulted.add(cutOff)) return;
    GameBus.instance
        .emit(PedestrianYieldViolationEvent(speedAtLine: playerCar.speed));
    final world = parent;
    if (world != null && !cutOff.startledByPlayer) {
      world.add(ReactionBubble(
        target: cutOff,
        player: playerCar,
        reaction: DriverReaction.failedToYield,
      ));
    }
  }

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
  Vector2? _debugPlayerLocal;
  List<Pedestrian> _debugPeds = const [];

  @override
  void render(Canvas canvas) {
    _drawGround(canvas);
    _drawPavement(canvas);
    _drawRoundedCurbs(canvas);
    _drawRoads(canvas);
    _drawBox(canvas);
    _drawCurbReturns(canvas); // round the inner corners cars turn around
    _drawMarkings(canvas);
    _drawStopLines(canvas);
    _drawLaneArrows(canvas);
    _drawCrosswalks(canvas);
    drawDecorations(canvas);
    // Signal heads hang over each lane and are painted by SignalHeadOverlay
    // (renderSignalHeadsOverlay), above the car layer.
    debugRenderSplines(canvas);
    if (kDebugMode && DebugState.showDebug) _drawZebraDebug(canvas);
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
        Rect.fromLTWH(0, 0, _w, _h), Paint()..color = groundColor);
  }

  void _drawPavement(Canvas canvas) {
    final p = Paint()..color = const Color(0xFFBDBDBD);
    final l = _cx - _half - kPavementWidth, r = _cx + _half;
    canvas.drawRect(Rect.fromLTWH(l, 0, kPavementWidth, _h), p);
    canvas.drawRect(Rect.fromLTWH(r, 0, kPavementWidth, _h), p);
    final t = _cy - _half - kPavementWidth, b = _cy + _half;
    canvas.drawRect(Rect.fromLTWH(0, t, _w, kPavementWidth), p);
    canvas.drawRect(Rect.fromLTWH(0, b, _w, kPavementWidth), p);
  }

  void _drawRoads(Canvas canvas) {
    final p = Paint()..color = const Color(0xFF424242);
    canvas.drawRect(Rect.fromLTWH(_cx - _half, 0, _half * 2, _h), p);
    canvas.drawRect(Rect.fromLTWH(0, _cy - _half, _w, _half * 2), p);
  }

  void _drawBox(Canvas canvas) {
    canvas.drawRect(
        Rect.fromCenter(
            center: const Offset(_cx, _cy), width: _half * 2, height: _half * 2),
        Paint()..color = const Color(0xFF4E4E4E));
  }

  void _drawRoundedCurbs(Canvas canvas) {
    final p = Paint()..color = const Color(0xFFBDBDBD);
    final l = _cx - _half - kPavementWidth, r = _cx + _half + kPavementWidth;
    final t = _cy - _half - kPavementWidth, b = _cy + _half + kPavementWidth;
    _curbWedge(canvas, l, t, -1, -1, p);
    _curbWedge(canvas, r, t, 1, -1, p);
    _curbWedge(canvas, l, b, -1, 1, p);
    _curbWedge(canvas, r, b, 1, 1, p);
  }

  /// Rounds the four INNER corners — where a pavement corner pokes into the box
  /// and turning traffic sweeps past — by shaving the sharp 90° tip off the
  /// pavement and repainting it road colour, leaving a rounded curb return. The
  /// grass-side corners are handled by [_drawRoundedCurbs]. Each ([sx], [sy])
  /// points from the box corner OUT into its pavement-corner block. The box is
  /// off-centre vertically (cx≠cy), so the corners split into X and Y edges.
  void _drawCurbReturns(Canvas canvas) {
    final road = Paint()..color = const Color(0xFF424242);
    const loX = _cx - _half, hiX = _cx + _half; // 440 / 760 — box X edges
    const loY = _cy - _half, hiY = _cy + _half; // 660 / 980 — box Y edges
    _curbWedge(canvas, hiX, hiY, 1, 1, road, _curbReturnRadius); // SE
    _curbWedge(canvas, loX, hiY, -1, 1, road, _curbReturnRadius); // SW
    _curbWedge(canvas, hiX, loY, 1, -1, road, _curbReturnRadius); // NE
    _curbWedge(canvas, loX, loY, -1, -1, road, _curbReturnRadius); // NW
  }

  void _curbWedge(Canvas canvas, double cornerX, double cornerY, int sx, int sy,
      Paint p, [double r = _curbRadius]) {
    final center = Offset(cornerX + sx * r, cornerY + sy * r);
    final p1 = Offset(cornerX, cornerY + sy * r);
    final p2 = Offset(cornerX + sx * r, cornerY);
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

  void _drawMarkings(Canvas canvas) {
    final yellow = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3;
    // Double-yellow centreline on each arm (outside the box).
    for (final dx in const [-4.0, 4.0]) {
      canvas.drawLine(Offset(_cx + dx, 0), Offset(_cx + dx, _cy - _half), yellow);
      canvas.drawLine(
          Offset(_cx + dx, _cy + _half), Offset(_cx + dx, _h), yellow);
    }
    for (final dy in const [-4.0, 4.0]) {
      canvas.drawLine(Offset(0, _cy + dy), Offset(_cx - _half, _cy + dy), yellow);
      canvas.drawLine(
          Offset(_cx + _half, _cy + dy), Offset(_w, _cy + dy), yellow);
    }
    // Dashed white lane dividers between the two lanes on each side of each arm.
    _dash(canvas, vertical: true, at: _cx + kLaneWidth); // player side 680
    _dash(canvas, vertical: true, at: _cx - kLaneWidth); // oncoming side 520
    _dash(canvas, vertical: false, at: _cy + kLaneWidth);
    _dash(canvas, vertical: false, at: _cy - kLaneWidth);
  }

  void _dash(Canvas canvas, {required bool vertical, required double at}) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 3;
    const dashLen = 40.0, gap = 40.0;
    if (vertical) {
      for (final seg in [
        [0.0, _cy - _half],
        [_cy + _half, _h]
      ]) {
        for (double y = seg[0]; y < seg[1]; y += dashLen + gap) {
          canvas.drawLine(
              Offset(at, y), Offset(at, (y + dashLen).clamp(seg[0], seg[1])), p);
        }
      }
    } else {
      for (final seg in [
        [0.0, _cx - _half],
        [_cx + _half, _w]
      ]) {
        for (double x = seg[0]; x < seg[1]; x += dashLen + gap) {
          canvas.drawLine(
              Offset(x, at), Offset((x + dashLen).clamp(seg[0], seg[1]), at), p);
        }
      }
    }
  }

  void _drawStopLines(Canvas canvas) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 8;
    final g = _stopLineFromCentre;
    // Each line spans that approach's two lanes (the near half of the road).
    canvas.drawLine(Offset(_cx, _cy + g), Offset(_cx + _half, _cy + g), p); // N-bound
    canvas.drawLine(Offset(_cx - _half, _cy - g), Offset(_cx, _cy - g), p); // S-bound
    canvas.drawLine(Offset(_cx - g, _cy), Offset(_cx - g, _cy + _half), p); // E-bound
    canvas.drawLine(Offset(_cx + g, _cy - _half), Offset(_cx + g, _cy), p); // W-bound
  }

  /// Lane-use arrows on each approach: inner lane ◄ (left only), outer lane
  /// ▲ + ► (through + right). Drawn for all four approaches via rotation.
  void _drawLaneArrows(Canvas canvas) {
    _drawApproachArrows(canvas, const Offset(0, -1)); // S approach (player)
    _drawApproachArrows(canvas, const Offset(0, 1)); // N approach
    _drawApproachArrows(canvas, const Offset(1, 0)); // W approach
    _drawApproachArrows(canvas, const Offset(-1, 0)); // E approach
  }

  void _drawApproachArrows(Canvas canvas, Offset travel) {
    final angle = math.atan2(travel.dx, -travel.dy);
    // Set ~100px further back than the stop line (was +70) so the lane arrows
    // read early on approach and clear the overhead heads/placards rather than
    // tucking under them. Still well inside the shortest (E/W) approach.
    final back = _half + _stopLineGap + 170.0;
    final centre = const Offset(_cx, _cy) - travel * back;
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(angle);
    // [centre] is on the road centreline; after rotation "up" (−y local) is the
    // travel direction and +x local is the right (driving) side. The two approach
    // lanes sit at +innerOff (inner, left-only ◄) and +outerOff (outer, ▲►).
    _arrowGlyph(canvas, paint, dx: _innerOff, kinds: _config.arrowKinds(isInner: true));
    _arrowGlyph(canvas, paint, dx: _outerOff, kinds: _config.arrowKinds(isInner: false));
    canvas.restore();
  }

  void _arrowGlyph(Canvas canvas, Paint paint,
      {required double dx, required List<String> kinds}) {
    for (final k in kinds) {
      final path = Path()..moveTo(dx, 26);
      switch (k) {
        case 'up':
          path.lineTo(dx, -26);
          _head(path, dx, -26, 0, -1);
          break;
        case 'left':
          path
            ..lineTo(dx, -6)
            ..lineTo(dx - 26, -6);
          _head(path, dx - 26, -6, -1, 0);
          break;
        case 'right':
          path
            ..lineTo(dx, -6)
            ..lineTo(dx + 26, -6);
          _head(path, dx + 26, -6, 1, 0);
          break;
      }
      canvas.drawPath(path, paint);
    }
  }

  void _head(Path path, double x, double y, double dirX, double dirY,
      [double s = 9.0]) {
    final px = -dirY, py = dirX; // perpendicular
    path
      ..moveTo(x - dirX * s + px * s, y - dirY * s + py * s)
      ..lineTo(x, y)
      ..lineTo(x - dirX * s - px * s, y - dirY * s - py * s);
  }

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
    // Stripes span the road the crossing covers: a N/S crossing (horizontalBand)
    // spans the vertical road (x∈cx±half); an E/W crossing spans the horizontal
    // road (y∈cy±half). cx≠cy now, so the two spans differ.
    final lo = (horizontalBand ? _cx : _cy) - _half;
    final hi = (horizontalBand ? _cx : _cy) + _half;
    if (horizontalBand) {
      final top = centreAlong - _crosswalkHalf;
      for (double x = lo + 4; x + stripe <= hi; x += stripe + gap) {
        canvas.drawRect(Rect.fromLTWH(x, top, stripe, _crosswalkHalf * 2), paint);
      }
    } else {
      final left = centreAlong - _crosswalkHalf;
      for (double y = lo + 4; y + stripe <= hi; y += stripe + gap) {
        canvas.drawRect(Rect.fromLTWH(left, y, _crosswalkHalf * 2, stripe), paint);
      }
    }
  }

  static const double _lampR = 8.0;

  /// Head scale — a hair smaller than full so a car waiting under the overhead
  /// head still reads through on either side (head ≈17 wide over an 80 lane).
  static const double _headScale = 1 / 1.5;

  /// Painted above the car layer by SignalHeadOverlay. One mast arm per
  /// approach: a curb pole, an arm over the carriageway, and a head hung above
  /// EACH of the two approaching lanes — footpath clear, a head over every lane.
  @override
  void renderSignalHeadsOverlay(Canvas canvas) => _drawSignalHeads(canvas);

  void _drawSignalHeads(Canvas canvas) {
    _drawSignalHeadFor(canvas, const Offset(0, -1), _phaseOf(_Heading.north));
    _drawSignalHeadFor(canvas, const Offset(0, 1), _phaseOf(_Heading.south));
    _drawSignalHeadFor(canvas, const Offset(1, 0), _phaseOf(_Heading.east));
    _drawSignalHeadFor(canvas, const Offset(-1, 0), _phaseOf(_Heading.west));
  }

  void _drawSignalHeadFor(Canvas canvas, Offset travel, SignalPhase phase) {
    final right = Offset(-travel.dy, travel.dx);
    final back = _half + _stopLineGap + 30.0;
    final base = const Offset(_cx, _cy) - travel * back;
    final angle = math.atan2(travel.dx, -travel.dy);

    // Pole on the curb edge; arm spans in over both lanes to the inner head.
    final pole = base + right * (_half + 6.0);
    canvas.drawLine(
        pole,
        base + right * _innerOff,
        Paint()
          ..color = const Color(0xFF4A4D52)
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(pole, 6, Paint()..color = const Color(0xFF2A2D32));

    for (final off in const [_innerOff, _outerOff]) {
      _drawHead(canvas, base + right * off, angle, phase);
    }

    // US-style overhead lane-use placards on the player's approach (north in
    // tile space) — an always-visible duplicate of the painted lane arrows,
    // which a car parked on them hides. Each placard advertises the active
    // config's rule for its lane; it sits just curb-side of its head.
    if (travel == const Offset(0, -1)) {
      _drawLaneUseSign(canvas, base + right * (_innerOff + _signGap), angle,
          _config.arrowKinds(isInner: true));
      _drawLaneUseSign(canvas, base + right * (_outerOff + _signGap), angle,
          _config.arrowKinds(isInner: false));
    }
  }

  static const double _signGap = 25.0; // placard offset, curb-side of the head

  /// US-style lane-use placard hung by a head: a white panel with black
  /// arrow(s) for the movements that lane allows ([kinds] mirrors the painted
  /// [_arrowGlyph]). Drawn in the overlay, so it stays visible above the cars.
  void _drawLaneUseSign(
      Canvas canvas, Offset center, double angle, List<String> kinds) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    const hw = 14.0, hh = 15.0;
    final panel = RRect.fromRectAndRadius(
        const Rect.fromLTRB(-hw, -hh, hw, hh), const Radius.circular(3));
    canvas.drawRRect(panel, Paint()..color = const Color(0xFFF5F5F5));
    canvas.drawRRect(
        panel,
        Paint()
          ..color = const Color(0xFF202225)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final ink = Paint()
      ..color = const Color(0xFF202225)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final k in kinds) {
      final path = Path()..moveTo(0, 10); // stem foot, toward the driver
      switch (k) {
        case 'up':
          path.lineTo(0, -9);
          _head(path, 0, -9, 0, -1, 5);
        case 'left':
          path
            ..lineTo(0, -1)
            ..lineTo(-9, -1);
          _head(path, -9, -1, -1, 0, 5);
        case 'right':
          path
            ..lineTo(0, -1)
            ..lineTo(9, -1);
          _head(path, 9, -1, 1, 0, 5);
      }
      canvas.drawPath(path, ink);
    }
    canvas.restore();
  }

  void _drawHead(Canvas canvas, Offset center, double angle, SignalPhase phase) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    canvas.scale(_headScale);
    final housing = RRect.fromRectAndRadius(
        const Rect.fromLTRB(-13, -30, 13, 30), const Radius.circular(6));
    canvas.drawRRect(housing, Paint()..color = const Color(0xFF202225));
    _lamp(canvas, const Offset(0, -18), phase == SignalPhase.red,
        const Color(0xFFFF1744), const Color(0x55FF1744), const Color(0xFF3A1417));
    _lamp(canvas, const Offset(0, 0), phase == SignalPhase.yellow,
        const Color(0xFFFFC400), const Color(0x55FFC400), const Color(0xFF3A3211));
    _lamp(canvas, const Offset(0, 18), phase == SignalPhase.green,
        const Color(0xFF00E676), const Color(0x5500E676), const Color(0xFF123A22));
    canvas.restore();
  }

  void _lamp(Canvas canvas, Offset at, bool lit, Color on, Color glow, Color off) {
    if (lit) canvas.drawCircle(at, _lampR + 5, Paint()..color = glow);
    canvas.drawCircle(at, _lampR, Paint()..color = lit ? on : off);
  }

  void _drawZebraDebug(Canvas canvas) {
    if (locale != LocaleType.urban) return;
    for (int idx = 0; idx < 4; idx++) {
      final busy =
          _debugPeds.any((p) => _zebraIndexOf(worldToLocal(p.position)) == idx);
      // (debug only — re-derive the band rect cheaply)
      final r = _zebraBandRect(idx);
      canvas.drawRect(r,
          Paint()..color = busy ? const Color(0x99FF1744) : const Color(0x55FFC400));
    }
    final pl = _debugPlayerLocal;
    if (pl != null) {
      canvas.drawCircle(Offset(pl.x, pl.y), 6, Paint()..color = const Color(0xFF00E5FF));
    }
  }

  Rect _zebraBandRect(int idx) {
    const along = _half + _zebraEnterMargin;
    switch (idx) {
      case 0:
        return Rect.fromLTRB(_cx - along, _cy + _crosswalkOffset - _zebraBandMargin,
            _cx + along, _cy + _crosswalkOffset + _zebraBandMargin);
      case 1:
        return Rect.fromLTRB(_cx - along, _cy - _crosswalkOffset - _zebraBandMargin,
            _cx + along, _cy - _crosswalkOffset + _zebraBandMargin);
      case 2:
        return Rect.fromLTRB(_cx - _crosswalkOffset - _zebraBandMargin, _cy - along,
            _cx - _crosswalkOffset + _zebraBandMargin, _cy + along);
      default:
        return Rect.fromLTRB(_cx + _crosswalkOffset - _zebraBandMargin, _cy - along,
            _cx + _crosswalkOffset + _zebraBandMargin, _cy + along);
    }
  }
}

enum _Zone { far, approaching, inBox, past }
