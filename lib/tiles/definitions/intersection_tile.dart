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
import '../../feedback/driver_reaction.dart';
import '../../feedback/reaction_bubble.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../scenarios/scenario_base.dart';
import '../scenarios/scenario_registry.dart';
import '../scenarios/stop_sign_scenario.dart';

/// Cardinal heading of a vehicle travelling through the intersection.
/// Ordered clockwise so `(index + 1) % 4` = next clockwise neighbour.
enum Heading { north, east, south, west }

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
    ScenarioBase? scenario,
  }) : super(scenario: scenario ?? StopSignScenario());

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

  /// Painted stop line offset from the conflict-box edge (world units).
  static const double _stopLineGap = 12.0;

  /// Tile-local Y of the player's stop line on the south approach. The yield
  /// rule is evaluated at this line, so the painted marking == the rule.
  static const double _playerStopLineY = _cy + _halfBox + _stopLineGap;

  /// How close to the stop line (along the approach) a complete stop must be
  /// made to count as stopping "at the sign" — ~1.5 car lengths. A full stop
  /// further back than this, followed by accelerating through the line, is a
  /// rolling stop, not a legal one.
  static const double _stopCreditWindow = kCarLength * 1.5;

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

    final going = _arbitrateAllWayStop(dt, samples);
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
      if (z != _Zone.approaching) {
        // In the box or past it — cruise through. (stopTargetDistance was
        // already cleared by super.updateNpcSensors.) Hold a calm speed while
        // still inside the box, resume normal speed once past it.
        npc.brain.intersectionRuleActive = false;
        npc.brain.hasRightOfWay = true;
        npc.brain.speedCap = z == _Zone.inBox ? kNpcTurnSpeed : null;
        continue;
      }
      final go = going.contains(npc);
      npc.brain.intersectionRuleActive = !go;
      npc.brain.hasRightOfWay = go;
      npc.brain.stopTargetDistance =
          go ? null : _gapToStopLine(heading, localPos);
      // A released car eases out of the line at a calm crossing speed rather
      // than flooring it — especially when it's taking a hesitating player's turn.
      npc.brain.speedCap = go ? kNpcTurnSpeed : null;
    }

    // The player legitimately waits while approaching/inside the box until the
    // arbiter releases it — used to exempt that stop from the road-blocking
    // penalty. (The player isn't *forced* to stop here; the stop-sign fault is
    // graded separately in [_checkPlayerStop].)
    final playerLocal = worldToLocal(playerCar.position);
    if (kDebugMode) _debugPlayerLocal = playerLocal;
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
        (pZone == _Zone.inBox && _otherCarInBox);

    // Player stop-sign violation detection.
    _checkPlayerStop(playerCar, samples);
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

  /// Run one frame of all-way-stop arbitration over [samples]; returns the ids
  /// committed to proceed (blocking the box, or released this frame).
  Set<Object> _arbitrateAllWayStop(double dt, List<_VehicleSample> samples) {
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
    // fresh-approach reset in [_checkPlayerStop].
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
        if (kDebugMode) {
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
        // longer blocks, so the cars waiting on it take their turn.
        if (!(v.id == _playerId && demotePlayer) &&
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
      // A left-turning player may pull into the box and yield to oncoming
      // traffic (the opposite approach, Heading.south) from within — entering
      // isn't a fault. So oncoming cars (whether going straight or turning
      // right into the same exit) don't trigger a fail-to-yield on a left turn;
      // only actually colliding does. Cross-traffic still counts.
      if (maneuver == Maneuver.left && o.heading == Heading.south) continue;
      // A conflicting car that's already mostly through the box (past its
      // centre) or gone is on its way out — pulling out behind it as it clears
      // is normal, not a fail-to-yield. (Uses the lenient past-centre test, not
      // the strict straight-only `_isClearing` used for NPC blocking, so a
      // turner that's nearly out also stops counting against the player.)
      final oz = zone[o.id];
      if (oz == _Zone.past ||
          (oz == _Zone.inBox && _pastBoxCentre(o.heading, o.localPos))) {
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
  bool _yieldViolationFired = false;
  bool _stopLineCrossed = false;
  bool _clearedReported = false;

  /// Whether the player came to a complete stop during the approach, and the
  /// slowest speed seen (for the fault message). Tracked across the whole
  /// approach window — not just the instant of crossing — so a stop made a
  /// little before the line, or an early stop followed by a creep, still counts.
  bool _cameToStop = false;
  double _minApproachSpeed = double.infinity;

  void _checkPlayerStop(
    PlayerCar playerCar,
    List<_VehicleSample> samples,
  ) {
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
    // crosses it. Two independent faults can be raised here:
    //   - stop-sign: no complete stop was made (mandatory regardless of
    //     traffic — the whole all-way-stop lesson);
    //   - fail-to-yield: the player crossed while a conflicting car had the
    //     right of way (in the box, or it stopped first), so it should have
    //     waited its turn. Only meaningful when there *is* traffic to yield to.
    if (!_stopLineCrossed && localY <= _playerStopLineY) {
      _stopLineCrossed = true;
      scenario.onPlayerPassedYieldLine(playerCar.speed);

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
    _drawMarkings(canvas);
    _drawStopLines(canvas);
    _drawStopSigns(canvas);
    debugRenderSplines(canvas);
    if (kDebugMode) _drawDebugTurns(canvas);
  }

  /// Player's tile-local position, cached each frame for the debug overlay.
  Vector2? _debugPlayerLocal;

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

  /// One STOP sign per approach, on the right-hand pavement of the entering
  /// lane, level with that approach's stop line — the signal that this junction
  /// demands a full stop.
  void _drawStopSigns(Canvas canvas) {
    final outX = _cx + kRoadWidth / 2 + kPavementWidth / 2; // right pavement
    final outY = _cy + kRoadWidth / 2 + kPavementWidth / 2;
    final lineGap = _halfBox + _stopLineGap;
    // S approach (N-bound, right = +x); N approach (S-bound, right = -x);
    // W approach (E-bound, right = +y); E approach (W-bound, right = -y).
    _drawStopSign(canvas, Offset(outX, _cy + lineGap));
    _drawStopSign(canvas, Offset(kTileSize - outX, _cy - lineGap));
    _drawStopSign(canvas, Offset(_cx - lineGap, outY));
    _drawStopSign(canvas, Offset(_cx + lineGap, kTileSize - outY));
  }

  void _drawStopSign(Canvas canvas, Offset center) {
    const r = _signRadius;
    final octagon = Path();
    for (int i = 0; i < 8; i++) {
      final a = (22.5 + 45.0 * i) * math.pi / 180.0;
      final p = Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a));
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
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  /// The constant "STOP" label — laid out once and reused across every sign and
  /// frame (the text/style never change), instead of rebuilding 4×/frame.
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
