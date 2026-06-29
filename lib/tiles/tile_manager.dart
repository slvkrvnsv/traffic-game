import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/game_bus.dart';
import '../core/maneuver.dart';
import '../core/spline.dart';
import '../core/utils.dart' show obbOverlap, pointToObbDistance;
import '../cars/player_car.dart';
import '../cars/npc_car.dart';
import '../feedback/driver_reaction.dart';
import '../feedback/reaction_bubble.dart';
import '../npc/npc_spawner.dart';
import '../pedestrians/pedestrian.dart';
import '../pedestrians/pedestrian_spawner.dart';
import '../debug/debug_state.dart';
import 'tile_base.dart';
import 'tile_connector.dart';
import 'tile_registry.dart';
import 'definitions/start_tile.dart';

/// Manages the rolling window of live tiles.
///
/// Keeps [kTilesAhead] tiles alive ahead of the player, spawning the next
/// tile before the player reaches the end of the current one, and despawning
/// old tiles once the player has moved well past them.
class TileManager extends Component {
  TileManager({
    required this.playerCar,
    required this.world,
    required this.pedestrians,
    required this.ambientPedestrians,
    this.testMode,
    this.testManeuver,
    this.testSequence,
    this.testLocale,
    this.testControl,
    Random? rng,
  }) : _rng = rng ?? Random();

  final PlayerCar playerCar;
  final World world;

  /// World-owned pedestrian registries (see GameWorld). Crossing pedestrians go
  /// in [pedestrians] (rules-relevant); ambient walkers in [ambientPedestrians].
  final List<Pedestrian> pedestrians;
  final List<Pedestrian> ambientPedestrians;

  /// If set, always generate this tile type (test mode).
  final TileType? testMode;

  /// If set, pin the commanded maneuver on every spawned tile (test mode).
  final Maneuver? testManeuver;

  /// If set, cycle this ordered list of tile types (test-mode course), starting
  /// with the first as the opening tile. Takes precedence over [testMode].
  final List<TileType>? testSequence;

  /// If set, pin every tile to this locale (test mode). Null → free-drive rolls
  /// the locale in stretches (see [_nextLocale]).
  final LocaleType? testLocale;

  /// If set, pin every intersection's control (test mode): all-way stop or
  /// traffic light. Null → the control is rolled (free-drive, or a "random"
  /// menu entry) via the scenario registry.
  final IntersectionControl? testControl;

  /// Next index into [testSequence]; advanced once per spawned tile.
  int _seqIndex = 0;

  bool get _isSequenced => testSequence != null && testSequence!.isNotEmpty;

  /// The next tile type from [testSequence], advancing (and wrapping) the index.
  TileType _nextSequencedType() =>
      testSequence![_seqIndex++ % testSequence!.length];

  final Random _rng;
  final NpcSpawner _spawner = NpcSpawner();

  /// Pedestrian spawners keyed by the tile that owns them. Created when a tile
  /// is added, ticked each frame while it's alive, disposed when it's culled.
  final Map<TileBase, List<PedestrianSpawner>> _pedSpawners = {};

  // --- Locale (urban/interurban) rolling, free-drive only -------------------
  // The locale runs in stretches of [kLocaleRunLength] tiles so the world keeps
  // a coherent setting for a while, then re-rolls (phase 5). Test mode pins it.
  LocaleType _currentLocale = LocaleType.interurban;
  int _localeRunRemaining = 0;

  /// The locale for the next tile slot. Consumes one slot of the current run;
  /// when a run is exhausted a fresh locale is rolled (it may repeat or flip).
  /// Called exactly once per spawned tile (NOT per placement retry, so a re-roll
  /// to dodge an overlap keeps the slot's locale).
  LocaleType _nextLocale() {
    if (testLocale != null) return testLocale!;
    final r = rollLocale(_currentLocale, _localeRunRemaining, _rng);
    _currentLocale = r.locale;
    _localeRunRemaining = r.remaining;
    return r.locale;
  }

  /// Pure roll for the next slot's locale (the source of truth the locale test
  /// drives). Holds [current] for the rest of the run; when [remaining] hits 0 a
  /// fresh locale is rolled and a new [kLocaleRunLength] run begins. Returns the
  /// locale for this slot and the remaining count to thread into the next call.
  @visibleForTesting
  static ({LocaleType locale, int remaining}) rollLocale(
      LocaleType current, int remaining, Random rng) {
    if (remaining <= 0) {
      current = LocaleType.values[rng.nextInt(LocaleType.values.length)];
      remaining = kLocaleRunLength;
    }
    return (locale: current, remaining: remaining - 1);
  }

  /// All live NPCs this session — owned by the spawner, exposed for the
  /// rules system (ViolationDetector).
  List<NpcCar> get allNpcs => _spawner.allNpcs;

  final List<TileBase> _activeTiles = [];

  /// Old tiles that have been handed off but are still potentially visible.
  /// Removed once far enough behind the player.
  final List<TileBase> _trailingTiles = [];

  // ---------------------------------------------------------------------------
  // Traffic density
  // ---------------------------------------------------------------------------

  /// Desired live NPC count per NPC-path per tile.
  static const int _targetNpcsPerPath = 2;

  /// How often (seconds) to check each path for missing traffic.
  static const double _refillInterval = 1.8;

  /// Don't spawn if the spawn point is within this distance of the player
  /// (prevents cars materialising on-screen). Must comfortably exceed the
  /// visible radius — at zoom [kCameraZoom] the camera shows ~screen/2/zoom
  /// world units in each direction, plus the [kCameraForwardOffset] look-ahead,
  /// so the worst-case (corner, ahead) visible distance from the player is
  /// roughly 1000 units on a phone. Spawning nearer than this is what made
  /// cars pop into view at the start of a tile.
  static const double _minSpawnDistFromPlayer = 1100.0;

  double _refillClock = 0.0;

  TileBase? get currentTile =>
      _activeTiles.isNotEmpty ? _activeTiles.first : null;

  /// Every tile currently in the world — active AND trailing — i.e. everything
  /// still being rendered. Walked by SignalHeadOverlay each frame so a junction
  /// you've just left keeps its heads until it's culled off-screen (matching
  /// the tile's own road, which renders until then). Active-only would pop the
  /// heads the instant you cross the seam, while the junction is still visible.
  List<TileBase> get liveTiles => [..._activeTiles, ..._trailingTiles];

  // ---------------------------------------------------------------------------
  // Bootstrap
  // ---------------------------------------------------------------------------

  void bootstrap() {
    _spawnInitialTile();
    _spawnNextTile();
  }

  TileBase _createTile(TileType type, LocaleType locale) => TileRegistry.create(
      type,
      TileSpawnContext(
          maneuver: testManeuver,
          rng: _rng,
          locale: locale,
          control: testControl));

  void _activateTile(TileBase tile) {
    tile.onActivate();
    GameBus.instance.emit(ManeuverAnnouncedEvent(
      maneuver: tile.commandedManeuver,
      label: tile.taskLabel,
    ));
  }

  void _spawnInitialTile() {
    // Normal play opens in the driving-school parking lot; test mode opens on
    // the chosen tile (or the first tile of a sequenced course) instead.
    final locale = _nextLocale();
    final tile = _isSequenced
        ? _createTile(_nextSequencedType(), locale)
        : (testMode != null
            ? _createTile(testMode!, locale)
            : StartTile(locale: locale));
    // First tile: canonical orientation, entry anchor at the world origin.
    tile.place(
      worldPosition: -tile.entryAnchor,
      orientation: 0.0,
    );
    _addTile(tile);

    _assignPlayerToTile(tile);
    playerCar.position.setFrom(playerCar.splinePosition);
    playerCar.angle = playerCar.splineAngle;

    _activateTile(tile);
    GameBus.instance.emit(TileReadyEvent(tileType: tile.tileType.name));
    debugPrint('[TILE] initial: ${tile.tileType.name} @ ${tile.position}');
  }

  /// Assign the player to [tile]. On a hand-off ([matchLane] true) the player
  /// may be in any of several parallel lanes, so pick the lane whose world
  /// entry is nearest the player's current *lane centreline* — mirroring the
  /// geometric match used for NPC seam continuity — otherwise lane 0 would snap
  /// them over. The centreline (not the rendered position) is used so a
  /// mid-lane-change lean doesn't bias the match and double-count the offset.
  /// On bootstrap there is no meaningful position yet, so use the first
  /// (default/seam) lane.
  void _assignPlayerToTile(TileBase tile, {bool matchLane = false}) {
    // Let a tile late-bind its commanded maneuver from the lane the player is
    // entering (the 2-lane light always sets a lane-change task) BEFORE its
    // playerPaths are read below. On a hand-off the player's lane centre is
    // meaningful; on bootstrap there's no position yet, so use the entry anchor
    // (the inner/seam lane), which the tile reads as "entered the inner lane".
    tile.bindPlayerEntry(
        matchLane ? playerCar.splineCentrePosition : tile.worldEntry);

    Spline lane = tile.playerPaths.first;
    if (matchLane && tile.playerPaths.length > 1) {
      final from = playerCar.splineCentrePosition;
      double best = double.infinity;
      for (final p in tile.playerPaths) {
        final entry = tile.localToWorld(p.evaluate(0.0));
        final d = entry.distanceTo(from);
        if (d < best) {
          best = d;
          lane = p;
        }
      }
    }
    // Carry the player's FULL world position (centreline + lean) across the seam, so a
    // mid-merge hand-off stays put: rebase lateralOffset against the NEW lane instead of
    // letting the raw offset apply to a fresh centreline. Every other spline switch
    // already does this (_commitToAdjacent / commitFork); the hand-off was the
    // one that didn't. A settled car has offset 0 → no-op; only a car mid-change moves.
    // Bootstrap (matchLane false) has no prior position, so skip it.
    final worldBefore = matchLane ? playerCar.splinePosition : null;
    playerCar.assignSpline(
      lane,
      worldOffset: tile.position,
      worldAngle: tile.orientation,
    );
    if (worldBefore != null) {
      final a = playerCar.splineAngle;
      playerCar.lateralOffset = (worldBefore - playerCar.splineCentrePosition)
          .dot(Vector2(-sin(a), cos(a)));
    }
    // Lane options follow the spline network: the mates of the lane just assigned
    // (for ordinary tiles this is the full lane set; an intersection narrows it past
    // a fork). Same as playerPaths for every current tile at entry — but routing
    // through it stays spline-driven.
    playerCar.setLaneOptions(
      tile.playerLaneMates(lane),
      tile.position,
      tile.orientation,
      allowLaneChange: tile.allowsLaneChange,
    );
  }

  // ---------------------------------------------------------------------------
  // Update loop
  // ---------------------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);
    _checkHandOff();
    _checkPlayerBranch();
    _advanceNpcsAcrossSeams(dt);
    _updateNpcSensors(dt);
    _commitExitChanges();
    _updatePedestrians(dt);
    _updatePlayerLaneChange();
    _cullDistantNpcs();
    _cullTrailingTiles();
    _tickRefill(dt);
    _updateDebugState();
  }

  /// Tick every live tile's pedestrian spawners (active and trailing, so a
  /// walker keeps moving after the player passes its tile) and add newcomers,
  /// then resolve pedestrian-vs-car yielding so nobody walks through a car.
  void _updatePedestrians(double dt) {
    for (final spawners in _pedSpawners.values) {
      for (final s in spawners) {
        for (final ped in s.update(dt, playerCar.position)) {
          world.add(ped);
        }
      }
    }
    _updatePedestrianSignals();
    _updatePedestrianCarAvoidance();
    _updatePedestrianPedAvoidance();
  }

  /// Hold each crossing pedestrian at the curb while a traffic light shows
  /// don't-walk for the crossing it is about to step onto (light intersections
  /// only — every other tile returns false). The decision is computed across the
  /// active tiles and set ONCE per pedestrian, so a tile that isn't the one the
  /// pedestrian is at never clears the hold another tile imposed.
  void _updatePedestrianSignals() {
    if (pedestrians.isEmpty) return;
    for (final ped in pedestrians) {
      final fwd = Vector2(cos(ped.angle), sin(ped.angle));
      bool held = false;
      for (final tile in _activeTiles) {
        if (tile.pedestrianHeldBySignal(ped.position, fwd)) {
          held = true;
          break;
        }
      }
      ped.setSignalHold(held);
    }
  }

  /// Pedestrians never walk through each other and never freeze face-to-face: a
  /// walker that ANTICIPATES converging too close with another (predicted from
  /// both their velocities) leans aside — a side-step on top of its keep-right
  /// offset — and keeps moving, easing back once they have passed. Both
  /// registries are scanned together (a road-crosser and a sidewalk stroller can
  /// meet at a corner). See [pedAvoidSideStep].
  ///
  /// Prediction runs on each ped's KEEP-RIGHT LANE position (centreline + base
  /// offset, EXCLUDING the dynamic lean) and intended velocity, so the lean never
  /// feeds back into its own detection — that feedback is what made an earlier,
  /// proximity-based version oscillate ("bounce") instead of drifting apart.
  void _updatePedestrianPedAvoidance() {
    final all = <Pedestrian>[...pedestrians, ...ambientPedestrians];
    if (all.length < 2) return;
    final lanePos = <Vector2>[];
    final vel = <Vector2>[];
    for (final p in all) {
      final a = p.splineAngle;
      final c = p.splineCentrePosition;
      lanePos.add(
          Vector2(c.x - sin(a) * kPedLaneOffset, c.y + cos(a) * kPedLaneOffset));
      vel.add(Vector2(cos(a) * p.walkSpeed, sin(a) * p.walkSpeed));
    }
    for (var i = 0; i < all.length; i++) {
      all[i].setAvoidance(pedAvoidSideStep(lanePos[i], vel[i], lanePos, vel));
    }
  }

  /// The signed lateral step (world units, +right of travel) a pedestrian at
  /// [pos] moving at [vel] should add to its keep-right offset to clear the MOST
  /// IMMINENT other walker it is predicted to pass too close to. Returns 0 when
  /// every pass is already clear. Two flavours, by how the other is moving:
  ///   * SAME direction (catching it up) → −2×[kPedLaneOffset]: swap to the open
  ///     opposite lane and overtake there, the way people actually pass;
  ///   * crossing / near-oncoming → ±[kPedSideStep] toward the side that opens
  ///     the gap (a dead-on meeting breaks to the right, which desyncs a
  ///     symmetric corner crossing so both clear).
  /// Anticipatory: for each other walker it computes the time of closest approach
  /// from the relative velocity and only reacts if that approach is soon
  /// ([kPedAvoidHorizon]), still ahead, and tighter than [kPedAvoidMiss]. Pure
  /// geometry (no component state) so it is unit-testable; [positions]/
  /// [velocities] are parallel and may include [pos] itself, skipped by identity.
  static double pedAvoidSideStep(Vector2 pos, Vector2 vel,
      List<Vector2> positions, List<Vector2> velocities) {
    final speed = vel.length;
    if (speed < 1e-6) return 0.0;
    final fwd = vel / speed;
    final right = Vector2(-fwd.y, fwd.x); // +lateralOffset direction
    double? bestTca;
    double suggested = 0.0;
    for (var i = 0; i < positions.length; i++) {
      final op = positions[i];
      if (identical(op, pos)) continue;
      final rp = op - pos;
      if (rp.dot(fwd) <= 0) continue; // only give way to someone ahead
      final ov = velocities[i];
      final rv = ov - vel;
      final vv = rv.dot(rv);
      final tca = vv < 1e-6 ? 0.0 : -rp.dot(rv) / vv; // time of closest approach
      if (tca < 0 || tca > kPedAvoidHorizon) continue; // past, or too far off
      final ca = rp + rv * tca; // relative position at closest approach
      if (ca.length > kPedAvoidMiss) continue; // will pass with room → ignore
      if (bestTca == null || tca < bestTca) {
        bestTca = tca;
        final os = ov.length;
        if (os > 1e-6 && fwd.dot(ov / os) > 0.5) {
          suggested = -2 * kPedLaneOffset; // overtake in the opposite lane
        } else {
          final lat = ca.dot(right);
          suggested = (lat > 0.5 ? -1.0 : 1.0) * kPedSideStep; // away from them
        }
      }
    }
    return bestTca == null ? 0.0 : suggested;
  }

  /// A road-crossing pedestrian respects a car's bounding box: it holds at the
  /// box edge rather than walking through it. Checks the pedestrian's next step
  /// against the player's box (held indefinitely — never walk through you, so no
  /// unfair crash) and against NPC boxes (held, with a timeout in the pedestrian
  /// that breaks a rare mutual stand-off). In the normal case an NPC yields and
  /// stops BEHIND the pedestrian, so its box is never on the path and the
  /// pedestrian crosses freely in front. A *moving* player drives into the
  /// holding pedestrian → collision, so failing to yield is still punished.
  void _updatePedestrianCarAvoidance() {
    if (pedestrians.isEmpty) return;
    const pw = 12.0; // pedestrian footprint
    for (final ped in pedestrians) {
      final fwd = Vector2(cos(ped.angle), sin(ped.angle));
      final probe = ped.position + fwd * kPedStepProbe; // its next step
      final byPlayer = obbOverlap(probe, pw, pw, ped.angle, playerCar.position,
          kCarWidth, kCarLength, playerCar.angle);
      bool byNpc = false;
      if (!byPlayer) {
        for (final npc in _spawner.allNpcs) {
          if (obbOverlap(probe, pw, pw, ped.angle, npc.position, kCarWidth,
              kCarLength, npc.angle)) {
            byNpc = true;
            break;
          }
        }
      }
      ped.setBlocked(player: byPlayer, npc: byNpc);

      // Personal space: the player's car body is inside the pedestrian's bubble
      // (~2× its footprint) → the ped startles, popping the SAME red "!" an NPC
      // car throws when cut off. Proximity-based (not the old next-step probe), so
      // it catches a hard stop a hair away — you're still MOVING as you cross the
      // 20u line, you just can't brake to zero instantly. Gated on motion so a
      // pedestrian merely walking past a car that is already STOPPED and waiting
      // (you yielded) does NOT startle them. Rising edge → once per intrusion.
      final wasStartled = ped.startledByPlayer;
      final intruded = pointToObbDistance(ped.position, playerCar.position,
              kCarWidth, kCarLength, playerCar.angle) <=
          kPedPersonalSpace;
      ped.setStartled(intruded);
      if (intruded && !wasStartled && playerCar.speed > kStopSpeedThreshold) {
        world.add(ReactionBubble(
          target: ped,
          player: playerCar,
          reaction: DriverReaction.failedToYield,
        ));
      }
    }
  }

  /// Gate the player's steering by position: the active tile decides whether a
  /// lane change is allowed where the player currently is (so a merge/widen lane
  /// can switch steering on/off mid-tile — see TileBase.allowsLaneChangeAt).
  void _updatePlayerLaneChange() {
    final tile = activeTile;
    if (tile == null) return;
    final local = tile.worldToLocal(playerCar.position);
    playerCar.setLaneChangeAllowed(tile.allowsLaneChangeAt(local));
  }

  void _updateNpcSensors(double dt) {
    for (final tile in _activeTiles) {
      tile.updateNpcSensors(dt, playerCar, _spawner.allNpcs, pedestrians);
    }
    // Trailing tiles keep their through-traffic driving (so cars don't freeze at
    // the seam behind a resting player — see [_advanceNpcsAcrossSeams]), so they
    // must still GOVERN those NPCs. Without this, an NPC on a junction the player
    // has driven past cruised on the brain's default right-of-way and drove
    // straight through pedestrians and stopped cars. Player grading is suppressed
    // — the player isn't on these tiles anymore.
    for (final tile in _trailingTiles) {
      tile.updateNpcSensors(dt, playerCar, _spawner.allNpcs, pedestrians,
          gradePlayer: false);
    }
  }

  /// A tile whose exit is decided late (the 2-lane light, "miss = straight")
  /// flags [TileBase.exitChanged] when the player commits their lane at the box;
  /// re-place its downstream tiles against the now-final exit.
  void _commitExitChanges() {
    final at = activeTile;
    if (at != null && at.exitChanged) {
      at.exitChanged = false;
      _rePlaceAfter(at);
    }
  }

  void _updateDebugState() {
    if (!kDebugMode || !DebugState.showDebug) return;
    final tile = activeTile;
    if (tile != null) DebugState.updateFromTile(tile);
    DebugState.activeTileCount = _activeTiles.length;
    DebugState.activeTileNames =
        _activeTiles.map((t) => '${t.tileType.name} @ (${t.position.x.toStringAsFixed(0)}, ${t.position.y.toStringAsFixed(0)})').toList();
    DebugState.playerSpeed = playerCar.speed;
    DebugState.playerT = playerCar.currentT;
    DebugState.playerX = playerCar.position.x;
    DebugState.playerY = playerCar.position.y;
    DebugState.playerBraking = playerCar.isBraking;
    DebugState.updateNpcs(_spawner.allNpcs);
  }

  void _checkHandOff() {
    final tile = currentTile;
    if (tile == null) return;

    // Spawn next tile early so it's ready when the player arrives.
    if (playerCar.currentT >= kHandOffTriggerT &&
        _activeTiles.length < kTilesAhead + 1) {
      _spawnNextTile();
    }

    // Hand off to the next tile when the player has reached the exact end of the
    // current spline (a through-lane spine, or a turn branch, runs to the tile edge).
    // Using hasReachedEnd (t=1.0) ensures the new spline's t=0 maps to the same world
    // position — no jump. In-tile TURN TAPS are resolved per-frame by
    // [_checkPlayerBranch], not here — they're mid-spline, not at the end.
    if (_activeTiles.length >= 2 && playerCar.hasReachedEnd) {
      _handOffToNextTile();
    }
  }

  /// Resolve in-tile TURN TAPS each frame. A turn branch hangs off the player's
  /// current through-lane spine — its start sits ON the spine, then it arcs away to a
  /// connected road. The player takes it by leaning toward its side while the branch
  /// still HUGS the lane: a commit ZONE (the lead-in plus the early arc, up to
  /// [kTurnCommitReach] off the lane), not one knife-edge point at the branch start.
  /// The switch projects onto the NEAREST point of the branch, so a turn steered as you
  /// REACH the intersection works — the natural late lean — instead of only a precise
  /// lean across the tap. Lean neutral → stay straight. The spine stays whole, so the
  /// merge (the player's SLIDE) never sees a seam.
  void _checkPlayerBranch() {
    final tile = activeTile;
    if (tile == null) return;
    final cur = playerCar.spline;
    if (cur == null) return;
    final commit = branchToCommit(
        playerCar, cur, tile.playerBranches(cur), playerCar.leanSign);
    if (commit == null) return;
    // Haptic on a TURN — diverting off the through lane should buzz.
    playerCar.commitFork(commit.branch, tile.playerLaneMates(commit.branch),
        tile.position, tile.orientation,
        startDistance: commit.startDistance,
        haptic: TileBase.pathTurns(commit.branch));
  }

  /// Which way [branch] turns off [spine]: −1 (left), +1 (right), 0 (straight). The
  /// signed turn of the branch's overall direction (start→end chord) vs the spine's
  /// heading, so a left-curving branch needs a left lean. Pure → unit-tested.
  @visibleForTesting
  static int branchSide(Spline spine, Spline branch) {
    final ref = spine.tangent(1.0);
    final d = branch.evaluate(1.0) - branch.evaluate(0.0);
    if (d.length < 1e-6) return 0;
    d.normalize();
    final s = atan2(ref.x * d.y - ref.y * d.x, ref.x * d.x + ref.y * d.y);
    return s < 0 ? -1 : (s > 0 ? 1 : 0);
  }

  /// The turn the player should divert onto this frame and WHERE to join it
  /// ([startDistance], the nearest point) — or null. Among the [branches] hung on
  /// [spine] whose side matches the held [lean] (−1/+1; 0 never diverts), the one the
  /// player sits CLOSEST to (smallest perpendicular offset) while that offset is still
  /// within [kTurnCommitReach] (the branch hasn't diverged past the commit zone) and
  /// the player is genuinely alongside it ([PlayerCar.nearestOn] non-null — not before
  /// its start nor past its end). Nearest-point, like the merge — so the commit is a
  /// ZONE, not a single point that gets consumed before you steer. Needs the live
  /// player (its position) → [@visibleForTesting] so tests drive the same wiring.
  @visibleForTesting
  static ({Spline branch, double startDistance})? branchToCommit(
      PlayerCar player, Spline spine, List<Spline> branches, int lean) {
    if (lean == 0 || branches.isEmpty) return null;
    Spline? best;
    double bestT = 0.0;
    double bestOffset = double.infinity;
    for (final b in branches) {
      if (branchSide(spine, b) != lean) continue; // leaning the other way
      final n = player.nearestOn(b);
      if (n == null) continue; // before the branch starts, or past its end
      final off = n.lateral.abs();
      if (off > kTurnCommitReach) continue; // diverged past the zone — too late to hop on
      if (off < bestOffset) {
        bestOffset = off;
        best = b;
        bestT = n.t;
      }
    }
    return best == null
        ? null
        : (branch: best, startDistance: bestT * best.totalLength);
  }

  void _handOffToNextTile() {
    final oldTile = _activeTiles.removeAt(0);
    oldTile.onDeactivate();

    final newTile = _activeTiles.first;

    // NPC continuity across the seam is handled continuously every frame by
    // _advanceNpcsAcrossSeams(), independent of the player's hand-off.

    // Assign BEFORE activating so a tile that late-binds its maneuver from the
    // entry lane (the 2-lane light) has it set before [_activateTile] announces
    // it. Mirrors the bootstrap order in [_spawnInitialTile] (assign → activate).
    _assignPlayerToTile(newTile, matchLane: true);
    // Binding may have just changed the new tile's EXIT direction (a late-bound
    // turn). Any downstream tiles already streamed in were placed against its old
    // (default) exit — re-place them so the corridor stays seamless.
    _rePlaceAfter(newTile);
    _activateTile(newTile);

    debugPrint('[TILE] handoff: ${oldTile.tileType.name} → ${newTile.tileType.name}'
        '  NPCs total=${_spawner.allNpcs.length}');

    GameBus.instance.emit(TileCompletedEvent(tileType: oldTile.tileType.name));
    GameBus.instance.emit(PlayerHandOffEvent());

    // Keep old tile in the world until it's far behind the camera.
    _trailingTiles.add(oldTile);
  }

  /// Re-place every tile downstream of [boundTile] against its (now-correct)
  /// predecessor, after [boundTile] late-bound its exit direction. Most tiles
  /// know their exit at spawn, so the recomputed placement is identical and they
  /// are skipped (no churn) — only a late-binding tile (the 2-lane light, whose
  /// turn isn't known until the player enters it) ever moves a downstream tile.
  /// A moved tile's NPCs are re-anchored to the new placement and its pedestrian
  /// spawners rebuilt (the spawner captures the offset at construction); the tile
  /// is a full tile ahead and off-screen, so the reshuffle is invisible.
  void _rePlaceAfter(TileBase boundTile) {
    final idx = _activeTiles.indexOf(boundTile);
    if (idx < 0) return;
    for (int i = idx + 1; i < _activeTiles.length; i++) {
      final prev = _activeTiles[i - 1];
      final tile = _activeTiles[i];
      final placement = TileConnector.computeNextPlacement(prev, tile);
      final moved =
          (tile.position - placement.worldPosition).length2 > 0.25 ||
              (tile.orientation - placement.orientation).abs() > 1e-6;
      if (!moved) continue;
      tile.place(
          worldPosition: placement.worldPosition,
          orientation: placement.orientation);
      for (final npc in tile.npcs) {
        final s = npc.spline;
        if (s != null) {
          npc.assignSpline(s,
              startDistance: npc.distanceTravelled,
              worldOffset: tile.position,
              worldAngle: tile.orientation);
        }
      }
      _disposePedSpawners(tile);
      _createPedSpawnersForTile(tile);
    }
  }

  // ---------------------------------------------------------------------------
  // Continuous NPC seam hand-off
  // ---------------------------------------------------------------------------

  /// Every frame, carry any NPC that has reached the end of its lane onto a
  /// connecting lane on a live tile, matched purely by geometry (seam position
  /// + travel direction). This keeps through-traffic flowing seamlessly and
  /// stops cars freezing at tile boundaries. NPCs with no continuation either
  /// despawn (behind the player) or briefly wait (ahead, off-screen) until the
  /// next tile streams in.
  void _advanceNpcsAcrossSeams(double dt) {
    // Snapshot first — we mutate tile.npcs lists while iterating. Trailing tiles
    // are included: through-traffic the player has passed keeps driving on the
    // tile behind them, and when it reaches that tile's far seam it must be
    // carried onto the active tile across the boundary. Iterating only the
    // active tiles left those cars stuck (parked) at the seam right behind a
    // resting player — visibly freezing, then getting culled.
    final reached = <(NpcCar, TileBase)>[];
    for (final tile in [..._activeTiles, ..._trailingTiles]) {
      for (final npc in tile.npcs) {
        if (npc.hasReachedEnd) reached.add((npc, tile));
      }
    }
    if (reached.isEmpty) return;

    final playerFwd = Vector2(cos(playerCar.angle), sin(playerCar.angle));

    for (final (npc, tile) in reached) {
      // Check occupancy BEFORE looking for a continuation. A blocked car holds at
      // the seam (see the hold-and-queue branch below) instead of stacking on a
      // car queued there (the cross-seam overlap bug) or rear-ending the player
      // stopped just ahead. Crucially, [_findContinuation] draws from the shared
      // map-generation [_rng] (it picks a random movement), so calling it every
      // frame for a car held at an occupied seam would couple congestion to the
      // seeded tile/locale/maneuver stream (non-determinism) and rescan all lanes
      // needlessly — skip it when blocked.
      final blocked = _seamEntryBlocked(npc);
      final next = blocked ? null : _findContinuation(npc);
      if (next != null) {
        // Carry momentum (speed is untouched) and the overflow distance so the
        // car re-enters the new lane exactly where it left off.
        npc.assignSpline(
          next.path,
          startDistance: npc.pendingOverflow.clamp(0.0, next.path.totalLength),
          worldOffset: next.tile.position,
          worldAngle: next.tile.orientation,
        );
        npc.pendingOverflow = 0.0;
        npc.seamWaitTime = 0.0; // found a continuation — no longer waiting
        npc.laneIndex = next.lane;
        // The continuation may bend (e.g. a turn through the next
        // intersection) — keep the indicator/turn-slow-down machinery honest.
        npc.brain.isTurning = TileBase.pathTurns(next.path);
        // A merge is done once the car crosses the seam — drop the forced left
        // signal so it doesn't carry onto the next tile (only the merge tile
        // ever sets it, so nothing would otherwise clear it).
        npc.brain.signalLeftForMerge = false;
        // Likewise, drop any intersection-only transient cues so they can't
        // stick onto the next tile (which never manages them).
        npc.brain.speedCap = null;
        npc.setHeadlightFlash(false);
        tile.npcs.remove(npc);
        next.tile.npcs.add(npc);
        continue;
      }

      // Blocked from carrying onto a LIVE continuation — its entry slot is taken.
      // Hold-and-queue: the car waits at the seam as the tail of a queue spanning
      // the boundary and carries the instant the slot clears (next frame, once the
      // occupant rolls forward). It never despawns on-screen — the visible pop the
      // gate would otherwise cause. It is already position-clamped at the seam, so
      // pinning it stopped is invisible (no jump) and keeps it from lunging into
      // the occupant on carry. No wait-timeout: a queue can outlast it, and the
      // normal distance cull reclaims the car off-screen if the player drives away
      // (a follower behind a stopped player instead carries the moment the player
      // pulls off — it follows them through, exactly the seamless case).
      if (blocked) {
        npc.speed = 0.0;
        npc.targetSpeed = 0.0;
        npc.seamWaitTime = 0.0;
        continue;
      }

      // No continuation. Only same-direction through-traffic still ahead of the
      // player is worth holding for — the tile ahead just hasn't streamed in
      // yet (and it's off-screen anyway). Everything else (oncoming/cross
      // traffic, or anything behind the player) has driven off the playable
      // corridor and despawns cleanly.
      final npcDir = Vector2(cos(npc.angle), sin(npc.angle));
      final sameWayAsPlayer = npcDir.dot(playerFwd) > 0.7;
      final ahead = (npc.position - playerCar.position).dot(playerFwd) >= 0;

      if (sameWayAsPlayer && ahead && npc.seamWaitTime < kSeamWaitTimeoutSeconds) {
        // Hold briefly for the tile ahead to stream in (normal driving streams
        // it well within the timeout). If it never comes — the player is
        // stationary, so no hand-off — give up rather than freeze forever and
        // leak the NPC budget; it's off-screen at the leading seam anyway.
        npc.speed = 0.0;
        npc.targetSpeed = 0.0;
        npc.seamWaitTime += dt;
      } else {
        npc.removeFromParent();
        _spawner.allNpcs.remove(npc);
        tile.npcs.remove(npc);
      }
    }
  }

  /// Whether the seam slot [npc] is about to be carried into is already occupied
  /// by another car (an NPC or the player) — too close ahead in the same lane to
  /// slot in without overlapping. The carried car starts at the seam, so its own
  /// world position is the entry; its heading is its travel direction.
  bool _seamEntryBlocked(NpcCar npc) {
    final heading = Vector2(cos(npc.angle), sin(npc.angle));
    for (final c in _spawner.allNpcs) {
      if (identical(c, npc)) continue;
      if (seamSlotBlocked(npc.position, heading, c.position)) return true;
    }
    return seamSlotBlocked(npc.position, heading, playerCar.position);
  }

  /// Pure occupancy test: does [other] occupy the seam entry slot at [entryPos]
  /// for a car heading [heading]? True when [other] sits anywhere from just
  /// behind the entry (on top of it) up to one car-length-plus-standing-gap
  /// ahead, in the same lane — i.e. there is no room to drop a car in without
  /// stacking. A car further ahead leaves room (the carried car queues behind it
  /// via normal lead-car following); a car well behind or in another lane is
  /// irrelevant.
  @visibleForTesting
  static bool seamSlotBlocked(Vector2 entryPos, Vector2 heading, Vector2 other) {
    final delta = other - entryPos;
    final fwd = delta.dot(heading);
    if (fwd < -kCarLength * 0.5) return false; // clearly behind the seam
    if (fwd > kCarLength + kNpcStandingGap) return false; // room to queue ahead
    final lateral = (delta - heading * fwd).length;
    return lateral <= kCarWidth * 1.5; // same lane → no room → blocked
  }

  /// Find a lane on any live tile that continues [npc]'s travel past the seam
  /// it just reached. Matches by world seam proximity and heading agreement.
  /// When several movements share the matched entry (an intersection lane
  /// offering straight/left/right), one is picked at random so through-traffic
  /// turns like real cars.
  ({TileBase tile, Spline path, int lane})? _findContinuation(NpcCar npc) {
    final endPos = npc.position;
    final endDir = Vector2(cos(npc.angle), sin(npc.angle));
    final current = npc.spline;

    const double seamTolerance = 30.0; // world units
    final candidates = <({TileBase tile, Spline path, int lane})>[];
    double bestDist = seamTolerance;

    for (final tile in [..._activeTiles, ..._trailingTiles]) {
      for (int lane = 0; lane < tile.npcLanes.length; lane++) {
        for (final path in tile.npcLanes[lane]) {
          if (identical(path, current)) continue; // never re-enter the same lane
          final start = tile.localToWorld(path.evaluate(0.0));
          final d = start.distanceTo(endPos);
          if (d > bestDist + 1.0) continue;
          if (tile.directionToWorld(path.tangent(0.0)).dot(endDir) < 0.7) {
            continue; // must head the same way
          }
          if (d < bestDist - 1.0) candidates.clear(); // strictly better seam
          bestDist = min(bestDist, d);
          candidates.add((tile: tile, path: path, lane: lane));
        }
      }
    }
    if (candidates.isEmpty) return null;
    return candidates[_rng.nextInt(candidates.length)];
  }

  // ---------------------------------------------------------------------------
  // Tile spawning
  // ---------------------------------------------------------------------------

  /// How many times to re-roll a tile whose footprint would overlap live
  /// tiles (a turn folding the corridor back onto itself) before giving up
  /// and accepting the overlap (degenerate but never deadlocks).
  static const int _placementRetries = 6;

  void _spawnNextTile() {
    final prevTile = _activeTiles.last;

    // Roll the locale once for this slot; the placement-retry re-rolls the tile
    // *type/geometry* to dodge overlaps but must keep the same locale.
    final locale = _nextLocale();
    TileBase tile = _createTile(_pickNextTileType(prevTile), locale);
    TilePlacement placement = TileConnector.computeNextPlacement(prevTile, tile);

    // A sequenced course is a fixed ordered list — re-rolling a tile to dodge an
    // overlap would both break the order and advance the sequence index twice.
    // Sequenced tiles are straight (exit faces north), so they never overlap.
    if (!_isSequenced) {
      final liveTiles = [..._activeTiles, ..._trailingTiles];
      for (int attempt = 0;
          attempt < _placementRetries &&
              TileConnector.overlapsAny(placement, tile.size, liveTiles);
          attempt++) {
        tile = _createTile(_pickNextTileType(prevTile), locale);
        placement = TileConnector.computeNextPlacement(prevTile, tile);
      }
    }

    tile.place(
      worldPosition: placement.worldPosition,
      orientation: placement.orientation,
    );
    _addTile(tile);

    debugPrint('[TILE] spawned: ${tile.tileType.name} @ ${tile.position}'
        '  rot=${(tile.orientation * 180 / pi).round()}°');
    GameBus.instance.emit(TileReadyEvent(tileType: tile.tileType.name));
  }

  void _addTile(TileBase tile) {
    world.add(tile);
    _activeTiles.add(tile);
    _spawnNpcsForTile(tile);
    _createPedSpawnersForTile(tile);
  }

  /// Build the pedestrian spawners a freshly-placed tile needs. Pedestrians
  /// leave the buildings: each spawner draws from the tile's [buildingExitRoutes]
  /// (door → sidewalk → along it), split by whether the route crosses a road —
  /// road-crossers go in the rules registry (cars/player yield, hitting one is a
  /// crash), sidewalk-only strollers in the visual-only registry. Tiles with no
  /// buildings fall back to the plain crossing/sidewalk lines. Placement is set
  /// (place() runs before _addTile), so splines map to world space.
  void _createPedSpawnersForTile(TileBase tile) {
    final spawners = <PedestrianSpawner>[];
    final urban = tile.locale == LocaleType.urban;

    final exits = tile.buildingExitRoutes;
    final crossing = <Spline>[];
    final sidewalk = <Spline>[];
    if (exits.isNotEmpty) {
      for (final e in exits) {
        (e.crossesRoad ? crossing : sidewalk).add(e.spline);
      }
    } else {
      // No buildings (interurban, or none placed) — walk the plain lines.
      crossing.addAll(tile.crossingPaths);
      sidewalk.addAll(tile.sidewalkPaths);
    }

    if (crossing.isNotEmpty) {
      spawners.add(PedestrianSpawner(
        paths: crossing,
        spawnIntervalSeconds: kCrossingPedInterval,
        registry: pedestrians,
        maxActive: kCrossingPedMax,
        minSpawnDist: kPedMinSpawnDist,
        worldOffset: tile.position,
        worldAngle: tile.orientation,
        rng: _rng,
      ));
    }
    if (sidewalk.isNotEmpty) {
      spawners.add(PedestrianSpawner(
        paths: sidewalk,
        spawnIntervalSeconds: urban
            ? kAmbientPedIntervalUrban
            : kAmbientPedIntervalInterurban,
        registry: ambientPedestrians,
        maxActive: urban ? kAmbientPedMaxUrban : kAmbientPedMaxInterurban,
        minSpawnDist: kPedMinSpawnDist,
        worldOffset: tile.position,
        worldAngle: tile.orientation,
        rng: _rng,
      ));
    }
    if (spawners.isNotEmpty) _pedSpawners[tile] = spawners;
  }

  void _spawnNpcsForTile(TileBase tile) {
    int count = 0;
    for (int lane = 0; lane < tile.npcLanes.length; lane++) {
      final path = _pickMovement(tile, lane);
      final spawnPos = tile.localToWorld(path.evaluate(0.0));
      // Same guard as the refill path: don't materialise a car on top of the player.
      if (playerCar.position.distanceTo(spawnPos) < _minSpawnDistFromPlayer) {
        continue;
      }
      final npc = _spawnOnPath(tile, lane, path);
      if (npc == null) break; // hard cap
      count++;
    }
    debugPrint('[NPC] spawned $count for ${tile.tileType.name}'
        '  total=${_spawner.allNpcs.length}');
  }

  /// Pick a random movement for [lane] — on intersections this is what makes
  /// NPC traffic turn left/right like real cars instead of only driving
  /// straight through.
  Spline _pickMovement(TileBase tile, int lane) {
    final group = tile.npcLanes[lane];
    return group[_rng.nextInt(group.length)];
  }

  NpcCar? _spawnOnPath(TileBase tile, int lane, Spline path) {
    final npc = _spawner.spawnSingle(
      path: path,
      tileOrigin: tile.position,
      tileAngle: tile.orientation,
      laneIndex: lane,
      isTurning: TileBase.pathTurns(path),
    );
    if (npc == null) return null; // hard cap
    tile.npcs.add(npc);
    world.add(npc);
    return npc;
  }

  /// Pick the next free-drive tile so the road stays lane-continuous: its entry
  /// seam must carry the same lane count [prevTile] exits with. So a 2-lane tile
  /// is followed by another 2-lane tile or a 2→1 merge; a 1-lane tile by another
  /// 1-lane tile or a 1→2 extend — a lane is only ever gained or dropped through
  /// a connector, never by one popping in or out. Two connectors are never
  /// chained back-to-back (that would flap the width with no road in between),
  /// so you always drive the lane count a connector hands you before the next
  /// transition.
  TileType _pickNextTileType(TileBase prevTile) {
    if (_isSequenced) return _nextSequencedType();
    if (testMode != null) return testMode!;
    return pickFreeDriveType(prevTile.tileType, _rng);
  }

  /// The lane-continuous free-drive pick (pure; the source of truth the chain
  /// test drives). Candidates are the spawnable tiles whose entry seam matches
  /// [prevType]'s exit lane count. If [prevType] *interrupts* the drive — a
  /// connector (lane transition) or a junction (intersection) — the candidates
  /// are narrowed to plain roads, so two interrupting tiles never chain
  /// back-to-back: the player always gets a normal stretch between them and is
  /// never asked to stop at two intersections in a row.
  @visibleForTesting
  static TileType pickFreeDriveType(TileType prevType, Random rng) {
    final exitLanes = TileRegistry.exitLanesOf(prevType);
    var candidates = TileRegistry.spawnableWithEntryLanes(exitLanes);
    if (_interrupts(prevType)) {
      final roads = candidates.where((t) => !_interrupts(t)).toList();
      if (roads.isNotEmpty) candidates = roads;
    }
    return candidates[rng.nextInt(candidates.length)];
  }

  /// A tile that breaks up a plain drive — a lane-transition connector or a
  /// junction. Two of these are never placed back-to-back.
  static bool _interrupts(TileType type) =>
      TileRegistry.isConnector(type) || TileRegistry.isJunction(type);

  // ---------------------------------------------------------------------------
  // NPC culling
  // ---------------------------------------------------------------------------

  void _cullDistantNpcs() {
    // Use the corridor heading (not the body angle, which carries lane-change
    // yaw) so "behind" stays stable during a lane change.
    final fwd = Vector2(cos(playerCar.splineAngle), sin(playerCar.splineAngle));
    _spawner.cullDistant(playerCar.position, fwd);
  }

  // ---------------------------------------------------------------------------
  // Trailing tile culling
  // ---------------------------------------------------------------------------

  /// Remove old tiles once the camera has clearly moved past them.
  void _cullTrailingTiles() {
    _trailingTiles.removeWhere((tile) {
      // Size-aware so a longer-than-square tile isn't culled while its far end
      // is still on screen: add however much the tile's largest dimension
      // exceeds a standard square tile. Square tiles keep the original distance.
      final cullDist = kTileSize * 1.2 +
          max(0.0, max(tile.size.x, tile.size.y) - kTileSize);
      if (playerCar.position.distanceTo(tile.worldCenter) > cullDist) {
        _disposePedSpawners(tile);
        tile.removeFromParent();
        debugPrint('[TILE] removed trailing: ${tile.tileType.name}');
        return true;
      }
      return false;
    });
  }

  /// Remove a culled tile's pedestrian spawners and their live walkers, so
  /// scenery never outlives the tile it belongs to.
  void _disposePedSpawners(TileBase tile) {
    final spawners = _pedSpawners.remove(tile);
    if (spawners == null) return;
    for (final s in spawners) {
      s.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Traffic refill
  // ---------------------------------------------------------------------------

  void _tickRefill(double dt) {
    _refillClock += dt;
    if (_refillClock < _refillInterval) return;
    _refillClock = 0.0;
    _refillTraffic();
  }

  /// For every NPC lane on every active tile, count alive NPCs and spawn one
  /// at the lane entry edge if the count is below [_targetNpcsPerPath].
  void _refillTraffic() {
    for (final tile in _activeTiles) {
      for (int lane = 0; lane < tile.npcLanes.length; lane++) {
        // Count NPCs still alive that belong to this tile + lane.
        final alive = tile.npcs
            .where((n) =>
                n.laneIndex == lane && _spawner.allNpcs.contains(n))
            .length;
        if (alive < _targetNpcsPerPath) {
          _trySpawnOnLane(tile, lane);
        }
      }
    }
  }

  /// Attempt to spawn one NPC at the entry edge of [tile]'s lane [laneIndex].
  /// Skipped if the spawn point is on-screen or another NPC is too close.
  void _trySpawnOnLane(TileBase tile, int laneIndex) {
    final path = _pickMovement(tile, laneIndex);
    final spawnPos = tile.localToWorld(path.evaluate(0.0));

    // Don't materialise a car in front of the player.
    if (playerCar.position.distanceTo(spawnPos) < _minSpawnDistFromPlayer) {
      return;
    }

    // Don't spawn if the entry point is jammed (another car is right there).
    final jammed = _spawner.allNpcs.any(
        (n) => n.position.distanceTo(spawnPos) < kNpcSafeGapDistance * 2.0);
    if (jammed) return;

    final npc = _spawnOnPath(tile, laneIndex, path);
    if (npc == null) return; // hard cap

    debugPrint('[NPC] refill L$laneIndex on ${tile.tileType.name}'
        '  total=${_spawner.allNpcs.length}');
  }

  // ---------------------------------------------------------------------------
  // Accessors for rules system
  // ---------------------------------------------------------------------------

  TileBase? get activeTile =>
      _activeTiles.isNotEmpty ? _activeTiles.first : null;
}
