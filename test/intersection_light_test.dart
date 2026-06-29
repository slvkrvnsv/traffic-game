import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/cars/car_variants.dart';
import 'package:traffic_game/cars/npc_car.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/traffic_signal.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/definitions/lane_config.dart';
import 'package:traffic_game/tiles/scenarios/lane_discipline_scenario.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';

void main() {
  group('geometry — approach lanes run straight, turn branches land right', () {
    IntersectionLightTile place() => IntersectionLightTile(config: LaneConfig.l1)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);

    // Tile is 1200 wide × 1640 tall, box centred at (600, 820). Lanes: N-bound
    // 640/720, exits — west-bound 780/700, east-bound 860/940, south edge 1640.
    const w = 1200.0, h = 1640.0, cy = 820.0;

    // Per-lane fork node: each lane forks where its TURN actually curves, so the
    // decision lands ON the visible fork. The inner (left) lane curves DEEPER —
    // cy+innerOff=860; the outer (right) lane at the box mouth — cy+half=980.
    const innerNodeY = 860.0;
    const outerNodeY = 980.0;

    test('both lane spines run straight the WHOLE tile height, 80u apart', () {
      final tile = place();
      tile.bindPlayerEntry(Vector2(720, h));
      expect(tile.playerPaths.length, 2);
      final inner = tile.playerPaths[0];
      final outer = tile.playerPaths[1];
      // Start in the two parallel lanes (at the south edge), 80u apart.
      expect(inner.evaluate(0.0).x, closeTo(640, 1));
      expect(inner.evaluate(0.0).y, closeTo(h, 1));
      expect(outer.evaluate(0.0).x, closeTo(720, 1));
      // Each spine is ONE continuous spline that runs the full height to the exit
      // edge (y=0) — NOT chopped at a node. That's what lets the corridor merge see a
      // continuous neighbour with no seam. The turns TAP on mid-spline (asserted next).
      expect(inner.evaluate(1.0).x, closeTo(640, 1));
      expect(inner.evaluate(1.0).y, closeTo(0, 1));
      expect(outer.evaluate(1.0).x, closeTo(720, 1));
      expect(outer.evaluate(1.0).y, closeTo(0, 1));
    });

    test('the left turns tap onto the inner spine at y=860 (near) then y=780 (far)', () {
      final tile = place();
      final spine = tile.approach(inner: true);
      final near = tile.branch(inner: true, m: Maneuver.left);
      final far = tile.farBranch(m: Maneuver.left);
      // Each turn's start sits ON the spine; its tap distance is the node depth.
      expect(spine.distanceAtNearest(near.evaluate(0.0)), closeTo(h - innerNodeY, 2));
      expect(spine.distanceAtNearest(far.evaluate(0.0)), closeTo(h - 780, 2));
      // Near taps EARLIER along the spine than far (shallower into the box).
      expect(spine.distanceAtNearest(near.evaluate(0.0)),
          lessThan(spine.distanceAtNearest(far.evaluate(0.0))));
    });

    test('the inner-lane LEFT branch runs from its (deeper) node out west', () {
      final left = place().branch(inner: true, m: Maneuver.left);
      expect(left.evaluate(0.0).x, closeTo(640, 1)); // starts at the inner node
      expect(left.evaluate(0.0).y, closeTo(innerNodeY, 1)); // deeper than the mouth
      expect(left.evaluate(1.0).x, closeTo(0, 2)); // exits west
      expect(left.evaluate(1.0).y, closeTo(cy - 40, 2)); // inner west-bound lane
    });

    test('the outer-lane RIGHT branch runs from the box mouth out east', () {
      final right = place().branch(inner: false, m: Maneuver.right);
      expect(right.evaluate(0.0).x, closeTo(720, 1)); // starts at the outer mouth
      expect(right.evaluate(0.0).y, closeTo(outerNodeY, 1));
      expect(right.evaluate(1.0).x, closeTo(w, 2)); // exits east
      expect(right.evaluate(1.0).y, closeTo(cy + 120, 2)); // outer east-bound lane
    });

    test('every turn taps EXACTLY onto its spine (coincident point → seamless divert)',
        () {
      final tile = place();
      for (final inner in [true, false]) {
        final spine = tile.approach(inner: inner);
        for (final b in tile.playerBranches(spine)) {
          final onSpine = spine.evaluate(
              spine.distanceToT(spine.distanceAtNearest(b.evaluate(0.0))));
          expect((b.evaluate(0.0) - onSpine).length, lessThan(1),
              reason: 'a turn must begin ON its spine → position-continuous divert');
        }
      }
    });

    test('every turn leaves heading ≈ north (smooth join, no kink at the tap)', () {
      final tile = place();
      for (final inner in [true, false]) {
        final spine = tile.approach(inner: inner);
        final north = spine.tangent(0.0); // a straight spine heads north everywhere
        for (final b in tile.playerBranches(spine)) {
          // No heading kink at the tap: the turn leaves heading ~north (the tight
          // right turn is the worst case, ~4° off with the finer arc sampling).
          expect(north.dot(b.tangent(0.0)), greaterThan(0.97),
              reason: 'turn entry tangent must match the spine heading');
        }
      }
    });

    test('no player branch or NPC path ever leaves the tile bounds', () {
      final tile = place()..bindPlayerEntry(Vector2(720, h));
      final all = <Spline>[...tile.playerBranchSplines, ...tile.npcPaths];
      for (final s in all) {
        for (int i = 0; i <= 30; i++) {
          final p = s.evaluate(i / 30);
          expect(p.x, inInclusiveRange(-6, w + 6));
          expect(p.y, inInclusiveRange(-6, h + 6));
        }
      }
    });

    test('there are 8 NPC lane groups (2 lanes × 4 approaches)', () {
      final tile = place();
      expect(tile.npcLanes.length, 8);
    });

    test('the commanded maneuver is a random pick from the config pool', () {
      // L1 pool is {left, straight, right}; every bound command is in it,
      // regardless of seed (entry lane forces nothing now).
      for (var seed = 0; seed < 12; seed++) {
        final tile = IntersectionLightTile(
            config: LaneConfig.l1, rng: math.Random(seed))
          ..place(worldPosition: Vector2.zero(), orientation: 0.0)
          ..bindPlayerEntry(Vector2(720, h));
        expect(LaneConfig.l1.commandable(), contains(tile.commandedManeuver));
      }
      // A pool with no left (straight/right split) never commands a left.
      for (var seed = 0; seed < 12; seed++) {
        final tile = IntersectionLightTile(
            config: LaneConfig.straightRightSplit, rng: math.Random(seed))
          ..place(worldPosition: Vector2.zero(), orientation: 0.0)
          ..bindPlayerEntry(Vector2(720, h));
        expect(tile.commandedManeuver, isNot(Maneuver.left));
      }
    });

    test('cross-traffic spans the correct axis (non-square per-heading authoring)', () {
      final tile = place();
      void at(Spline s, double t, double x, double y) {
        expect(s.evaluate(t).x, closeTo(x, 2));
        expect(s.evaluate(t).y, closeTo(y, 2));
      }

      // Group order: [north, east, south, west] × [inner, outer].
      // N-bound inner straight spans the tall axis (y: 1640 → 0) at x=640.
      at(tile.npcLanes[0][0], 0.0, 640, h);
      at(tile.npcLanes[0][0], 1.0, 640, 0);
      // E-bound inner straight spans the WIDE axis (x: 0 → 1200) at y=cy+40=860 —
      // NOT 1640 wide; a rotation bug would push it off the 1200-wide tile.
      at(tile.npcLanes[2][0], 0.0, 0, cy + 40);
      at(tile.npcLanes[2][0], 1.0, w, cy + 40);
      // S-bound inner straight spans the tall axis the other way at x=cx-40=560.
      at(tile.npcLanes[4][0], 0.0, 560, 0);
      at(tile.npcLanes[4][0], 1.0, 560, h);
    });
  });

  group('turn taps (merge-first reachable turns)', () {
    IntersectionLightTile place() => IntersectionLightTile(config: LaneConfig.l1)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);

    test('four player turns: near + far each way (straight is no longer a spline)', () {
      final tile = place();
      expect(tile.playerBranchSplines.length, 4);
      // Merge-first holds: left only from the inner lane, right only the outer.
      expect(() => tile.branch(inner: true, m: Maneuver.left), returnsNormally);
      expect(() => tile.farBranch(m: Maneuver.left), returnsNormally);
      expect(() => tile.branch(inner: false, m: Maneuver.right), returnsNormally);
      expect(() => tile.farBranch(m: Maneuver.right), returnsNormally);
    });

    test('each spine carries its two turns as taps (inner→left, outer→right)', () {
      final tile = place();
      expect(tile.playerBranches(tile.approach(inner: true)).toSet(), {
        tile.branch(inner: true, m: Maneuver.left),
        tile.farBranch(m: Maneuver.left),
      });
      expect(tile.playerBranches(tile.approach(inner: false)).toSet(), {
        tile.branch(inner: false, m: Maneuver.right),
        tile.farBranch(m: Maneuver.right),
      });
      // A turn carries no further taps → terminal, hands off at the exit edge.
      expect(tile.playerBranches(tile.branch(inner: true, m: Maneuver.left)), isEmpty);
    });

    test('the FAR turns land in the OTHER exit lane (one over from the near turn)', () {
      final tile = place();
      // near-left → inner west-bound (780); far-left → outer west-bound (700).
      expect(tile.branch(inner: true, m: Maneuver.left).evaluate(1.0).y,
          closeTo(780, 2));
      expect(tile.farBranch(m: Maneuver.left).evaluate(1.0).y, closeTo(700, 2));
      // near-right → outer east-bound (940); far-right → inner east-bound (860).
      expect(tile.branch(inner: false, m: Maneuver.right).evaluate(1.0).y,
          closeTo(940, 2));
      expect(tile.farBranch(m: Maneuver.right).evaluate(1.0).y, closeTo(860, 2));
    });

    test('branch directions order left < straight < right (so the lean picks right)',
        () {
      // TileManager picks the branch by the SIGNED TURN of its start→end chord vs the
      // approach heading (− left, ~0 straight, + right). Assert that ordering so a
      // left lean lands LEFT, neutral STRAIGHT, right lean RIGHT.
      final tile = place();
      double signedTurn(Spline app, Spline b) {
        final ref = app.tangent(1.0);
        final d = (b.evaluate(1.0) - b.evaluate(0.0))..normalize();
        return ref.x * d.y - ref.y * d.x; // sign: − left, + right (screen y-down)
      }

      final inApp = tile.approach(inner: true);
      expect(signedTurn(inApp, tile.branch(inner: true, m: Maneuver.left)),
          lessThan(-0.2)); // bends left
      expect(signedTurn(inApp, tile.branch(inner: true, m: Maneuver.straight)).abs(),
          lessThan(0.05)); // ~ straight
      final outApp = tile.approach(inner: false);
      expect(signedTurn(outApp, tile.branch(inner: false, m: Maneuver.right)),
          greaterThan(0.2)); // bends right
    });

    test('haptic gating: a straight fork does NOT turn; left/right do (TileBase.pathTurns)',
        () {
      final tile = place();
      // The manager clicks the wheel only when commitFork gets a TURNING branch, so
      // sliding straight through stays silent while a turn buzzes.
      expect(TileBase.pathTurns(tile.branch(inner: true, m: Maneuver.straight)),
          isFalse);
      expect(TileBase.pathTurns(tile.branch(inner: false, m: Maneuver.straight)),
          isFalse);
      expect(TileBase.pathTurns(tile.branch(inner: true, m: Maneuver.left)), isTrue);
      expect(TileBase.pathTurns(tile.branch(inner: false, m: Maneuver.right)), isTrue);
    });

    test('the corridor is ONE merge group of both WHOLE spines (a tap never kills merge)',
        () {
      final tile = place();
      // Both lane spines are one continuous spline each, in one merge group. Hanging a
      // turn on the outer spine doesn't remove it from the group — the spine keeps
      // running beside you the whole height. No stub seams to go blind at.
      final mates = tile.playerLaneMates(tile.approach(inner: true));
      expect(mates, contains(tile.approach(inner: false)));
      expect(mates.length, 2);
    });

    test('a turn keeps a neighbouring exit lane to merge into (the spline is king)',
        () {
      final tile = place();
      // After the fork the magnetic merge must keep working — a turn isn't a dead-end
      // single lane; it has its concentric sibling in the other exit lane.
      for (final m in [Maneuver.straight, Maneuver.left]) {
        final mates = tile.playerLaneMates(tile.branch(inner: true, m: m));
        expect(mates.length, greaterThanOrEqualTo(2),
            reason: '$m should expose a mergeable neighbour');
        expect(mates.any((s) => identical(s, tile.branch(inner: true, m: m))), isTrue);
      }
      expect(
          tile.playerLaneMates(tile.branch(inner: false, m: Maneuver.right)).length,
          greaterThanOrEqualTo(2));
    });

    test('a spine carries taps; a turn is terminal (normal hand-off at the exit)', () {
      final tile = place();
      expect(tile.playerBranches(tile.approach(inner: true)), isNotEmpty);
      // A turn offers no further taps → the player hands off to the next tile at its
      // exit edge instead of re-forking.
      expect(tile.playerBranches(tile.branch(inner: true, m: Maneuver.left)), isEmpty);
    });

    test('branchSide reads which way each tap turns (left taps left, right taps right)',
        () {
      final tile = place();
      final inner = tile.approach(inner: true);
      final outer = tile.approach(inner: false);
      // Left turns hang on the inner spine and curve LEFT (−1); right turns on the
      // outer spine and curve RIGHT (+1) — near and far of a side share the side.
      expect(TileManager.branchSide(inner, tile.branch(inner: true, m: Maneuver.left)),
          -1);
      expect(TileManager.branchSide(inner, tile.farBranch(m: Maneuver.left)), -1);
      expect(
          TileManager.branchSide(outer, tile.branch(inner: false, m: Maneuver.right)),
          1);
      expect(TileManager.branchSide(outer, tile.farBranch(m: Maneuver.right)), 1);
      // The lean → commit ZONE itself (a lean toward a tap takes that turn; neutral or
      // wrong-way stays straight; skip-near → far) is driven end-to-end on the real
      // PlayerCar in intersection_fork_test.
    });
  });

  group('LaneConfig.l1 — the lane-discipline rule (L1 layout)', () {
    test('left turn is legal only from the inner (centre-side) lane', () {
      expect(LaneConfig.l1.allows(isInner: true, m: Maneuver.left), isTrue);
      expect(LaneConfig.l1.allows(isInner: false, m: Maneuver.left), isFalse);
    });
    test('straight and right are legal only from the outer (curb) lane', () {
      expect(LaneConfig.l1.allows(isInner: false, m: Maneuver.straight), isTrue);
      expect(LaneConfig.l1.allows(isInner: true, m: Maneuver.straight), isFalse);
      expect(LaneConfig.l1.allows(isInner: false, m: Maneuver.right), isTrue);
      expect(LaneConfig.l1.allows(isInner: true, m: Maneuver.right), isFalse);
    });
  });

  group('signalStopTarget — commit & clear', () {
    test('green never stops for the light', () {
      expect(IntersectionLightTile.signalStopTarget(true, 100, null), isNull);
    });
    test('red still before the line holds at it', () {
      expect(IntersectionLightTile.signalStopTarget(false, 100, null), 100);
    });
    test('at/past the line gets no light stop (commit & clear)', () {
      expect(IntersectionLightTile.signalStopTarget(false, -10, null), isNull);
      expect(IntersectionLightTile.signalStopTarget(false, 0, null), isNull);
    });
    test('a pedestrian ahead is still yielded to, even on green', () {
      expect(IntersectionLightTile.signalStopTarget(true, 100, 50), 50);
    });
    test('the nearer of the line and the pedestrian wins', () {
      expect(IntersectionLightTile.signalStopTarget(false, 30, 80), 30);
      expect(IntersectionLightTile.signalStopTarget(false, 80, 30), 30);
    });
  });

  group('cannotClearBox — don\'t block the box', () {
    test('no stopped lead, or already in the box → can enter', () {
      expect(IntersectionLightTile.cannotClearBox(100, null), isFalse);
      expect(IntersectionLightTile.cannotClearBox(-5, 10), isFalse);
    });
    test('a near stopped lead leaving no room past the far edge → cannot clear', () {
      // needs room for the body + a standing gap beyond the far edge.
      final need = 100 + kCarLength + kNpcStandingGap;
      expect(IntersectionLightTile.cannotClearBox(100, need - 1), isTrue);
      expect(IntersectionLightTile.cannotClearBox(100, need + 1), isFalse);
    });
  });

  group('leftTurnCutsOffOncoming — fail-to-yield discriminator', () {
    test('a too-slow oncoming car is never "cut off"', () {
      expect(
          IntersectionLightTile.leftTurnCutsOffOncoming(kReactMinSpeed * 0.5, 5),
          isFalse);
    });
    test('a fast oncoming car forced to brake hard by a tiny gap is cut off', () {
      expect(IntersectionLightTile.leftTurnCutsOffOncoming(kNpcMaxSpeed, 10), isTrue);
    });
    test('turning into a generous gap is legal', () {
      expect(
          IntersectionLightTile.leftTurnCutsOffOncoming(kNpcMaxSpeed, 1000), isFalse);
    });
  });

  group('leftTurnFailsToYield — fault trigger (hard-brake OR close cut-off)', () {
    bool f(double speed, double gap) =>
        IntersectionLightTile.leftTurnFailsToYield(speed, gap);

    test('a fast oncoming car forced to brake hard is a fail-to-yield', () {
      expect(f(kNpcMaxSpeed, 10), isTrue);
    });
    test('a CRAWLING but moving car cut off at close range is a fail-to-yield '
        '(the straight-goer-behind-a-left-turner case the hard-brake test missed)',
        () {
      // Below kReactMinSpeed so the hard-brake path is false, but it IS moving and
      // the player took the crossing a fraction of a car-length ahead of it.
      expect(f(kReactMinSpeed * 0.5, 10), isTrue);
    });
    test('a STOPPED oncoming car is never cut off (legal turn in front of it)', () {
      expect(f(kStopSpeedThreshold * 0.5, 5), isFalse);
      expect(f(0, 0), isFalse);
    });
    test('a moving car at a generous gap is legal (no fault)', () {
      expect(f(kReactMinSpeed * 0.5, 1000), isFalse);
      expect(f(kNpcMaxSpeed, 1000), isFalse);
    });
  });

  group('pedMustHoldForSignal — walk-phase compliance', () {
    test('no crossing on the next step → never held', () {
      expect(
          IntersectionLightTile.pedMustHoldForSignal(
              -1, 0, 1, SignalPhase.red, SignalPhase.red),
          isFalse);
    });
    test('a ped about to cross the N–S road holds while it is not red', () {
      // band 0 crosses N–S; not yet committed (well on the entry side).
      expect(
          IntersectionLightTile.pedMustHoldForSignal(
              0, 250, -1, SignalPhase.green, SignalPhase.red),
          isTrue,
          reason: 'N–S green = cars moving = walk must wait');
      expect(
          IntersectionLightTile.pedMustHoldForSignal(
              0, 250, -1, SignalPhase.red, SignalPhase.green),
          isFalse,
          reason: 'N–S red = cars stopped = walk');
    });
    test('a committed ped (past the near edge) finishes crossing, never re-held', () {
      // travel +x, already past the near carriageway edge in its direction.
      expect(
          IntersectionLightTile.pedMustHoldForSignal(
              0, 0, 1, SignalPhase.green, SignalPhase.red),
          isFalse);
    });
    test('bands 2/3 track the E–W phase, not N–S', () {
      expect(
          IntersectionLightTile.pedMustHoldForSignal(
              3, 250, -1, SignalPhase.red, SignalPhase.green),
          isTrue);
    });
  });

  group('zebra bands — perpendicular crossings clear the box corners', () {
    // The four crossings' detection bands must NOT overlap at the box corners.
    // At the old +30 offset a corner point satisfied a N/S band AND an E/W band,
    // so a ped strolling one corner was mis-attributed to the cross-street's
    // crossing → false NPC yields + a false give-way fault on the player. The +58
    // offset separates them (mirrors the 1-lane intersection's clearance). Bands
    // are geometric — independent of locale — so a plain tile suffices.
    IntersectionLightTile place() => IntersectionLightTile(config: LaneConfig.l1)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    const cx = 600.0, cy = 820.0, off = 218.0; // _cx, _cy, _crosswalkOffset

    test('a ped on each crossing still reads its own band (no false negative)', () {
      final tile = place();
      expect(tile.zebraBandAt(Vector2(cx, cy + off)), 0, reason: 'south');
      expect(tile.zebraBandAt(Vector2(cx, cy - off)), 1, reason: 'north');
      expect(tile.zebraBandAt(Vector2(cx - off, cy)), 2, reason: 'west');
      expect(tile.zebraBandAt(Vector2(cx + off, cy)), 3, reason: 'east');
      // mid-south-crossing, near the road edge → still band 0.
      expect(tile.zebraBandAt(Vector2(cx + 150, cy + off)), 0);
    });

    test('a corner-stroller is on NO crossing (was a N/S band at +30)', () {
      final tile = place();
      // Just outside each box corner (760±, 980±). At +30 these read as a N/S
      // crossing (the overlap bug); at +58 they must be -1 (no crossing).
      for (final p in const [
        [770.0, 990.0], // SE
        [770.0, 650.0], // NE
        [430.0, 990.0], // SW
        [430.0, 650.0], // NW
      ]) {
        expect(tile.zebraBandAt(Vector2(p[0], p[1])), -1,
            reason: 'corner (${p[0]},${p[1]}) must not read as a crossing');
      }
    });
  });

  group('trailing-tile governance — NPCs governed, player NOT graded (anti-ghost)', () {
    // A junction the player has driven PAST is still sensed (gradePlayer:false):
    // its through-traffic MUST stay governed — un-governed it cruises on the
    // brain's default right-of-way and ghosts through peds + stopped cars — while
    // the player, no longer on the tile, must NOT be graded (no stale faults).

    test('a red-arm NPC still holds when gradePlayer is false (does not ghost)', () {
      // seed-0 origin → N–S green, so the E–W arms are RED.
      final tile = IntersectionLightTile(config: LaneConfig.l1)
        ..place(worldPosition: Vector2.zero(), orientation: 0.0);
      final spline = tile.npcLanes[2][0]; // east inner straight (a RED arm)
      final npc = NpcCar(
          definition: CarVariants.all.first, profileSpeed: kmhToUnits(40))
        ..laneIndex = 2
        ..assignSpline(spline, startDistance: 300, worldOffset: Vector2.zero());
      npc.position = npc.splinePosition;
      npc.speed = kmhToUnits(40);
      tile.npcs
        ..clear()
        ..add(npc);

      tile.updateNpcSensors(
          1 / 60, PlayerCar()..speed = 0, tile.npcs, const [],
          gradePlayer: false);

      expect(npc.brain.hasRightOfWay, isFalse,
          reason: 'red arm → it yields even on a passed (trailing) junction');
      expect(npc.brain.intersectionRuleActive, isTrue);
      expect(npc.brain.stopTargetDistance, isNotNull,
          reason: 'the stop hold runs regardless of gradePlayer (no ghost)');
    });

    test('the player wait flag is set only when gradePlayer is true', () {
      // Placed so N–S starts RED (seed = x + y*31 = 450 → the red half of the
      // cycle); approach the north arm. Grading on → the player must wait; grading
      // off (trailing) → the player isn't judged on a tile it has left.
      IntersectionLightTile redApproach() =>
          IntersectionLightTile(config: LaneConfig.l1)
            ..place(worldPosition: Vector2(450, 0), orientation: 0.0);
      PlayerCar approaching(IntersectionLightTile t) => PlayerCar()
        ..position = t.localToWorld(Vector2(640, 1100)) // north approach zone
        ..speed = kmhToUnits(30);

      final active = redApproach();
      active.updateNpcSensors(1 / 60, approaching(active), const [], const []);
      expect(active.playerMustWait, isTrue,
          reason: 'red + approaching → the active tile makes the player wait');

      final trailing = redApproach();
      trailing.updateNpcSensors(
          1 / 60, approaching(trailing), const [], const [],
          gradePlayer: false);
      expect(trailing.playerMustWait, isFalse,
          reason: 'a passed junction does not grade/flag the player');
    });
  });

  group('LaneDisciplineScenario grading', () {
    test('a wrong-lane traversal fails the run', () {
      final s = LaneDisciplineScenario();
      s.onWrongLane();
      expect(s.result.status, ScenarioStatus.failed);
      // and a later clean clear does NOT turn it into a pass.
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.failed);
    });
    test('a clean clear in the correct lane on green is a pass', () {
      final s = LaneDisciplineScenario();
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.passed);
    });
    test('the light rules still apply — running a red fails', () {
      final s = LaneDisciplineScenario();
      s.onRedLightViolation();
      expect(s.result.status, ScenarioStatus.failed);
    });
    test('reset clears both the lane fault and the light state', () {
      final s = LaneDisciplineScenario();
      s.onWrongLane();
      s.reset();
      expect(s.result.status, ScenarioStatus.ongoing);
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.passed);
    });
    test('a MISSED-TURN traversal fails the run (and a clean clear stays failed)',
        () {
      final s = LaneDisciplineScenario();
      s.onMissedTurn();
      expect(s.result.status, ScenarioStatus.failed);
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.failed);
    });
    test('a wrong-EXIT-lane traversal fails the run (and a clean clear stays failed)',
        () {
      final s = LaneDisciplineScenario();
      s.onWrongExitLane();
      expect(s.result.status, ScenarioStatus.failed);
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.failed);
    });
    test('reset clears a missed-turn fault too', () {
      final s = LaneDisciplineScenario();
      s.onMissedTurn();
      s.reset();
      expect(s.result.status, ScenarioStatus.ongoing);
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.passed);
    });
  });

  group('laneVerdict — lane-discipline grading (L1: left=inner, straight/right=outer)',
      () {
    LaneFault? verdict({
      required bool inner,
      required Maneuver did,
      required Maneuver commanded,
      bool farExit = false,
    }) =>
        IntersectionLightTile.laneVerdict(
            config: LaneConfig.l1,
            inner: inner,
            did: did,
            commanded: commanded,
            farExit: farExit);

    test('clean traversals earn no fault', () {
      expect(verdict(inner: true, did: Maneuver.left, commanded: Maneuver.left),
          isNull);
      expect(
          verdict(inner: false, did: Maneuver.right, commanded: Maneuver.right),
          isNull);
      expect(
          verdict(
              inner: false, did: Maneuver.straight, commanded: Maneuver.straight),
          isNull);
    });
    test('MISSED the turn: ended up somewhere other than the instruction', () {
      // Commanded a turn, drove straight — from the LEGAL lane (the dodge)...
      expect(
          verdict(inner: true, did: Maneuver.straight, commanded: Maneuver.left),
          LaneFault.missedTurn);
      // ...and from the WRONG lane too — still a missed turn, not a lane
      // technicality (this is "skip the task and go somewhere else").
      expect(
          verdict(
              inner: false, did: Maneuver.straight, commanded: Maneuver.left),
          LaneFault.missedTurn);
      // Commanded straight, took a turn instead.
      expect(
          verdict(
              inner: false, did: Maneuver.right, commanded: Maneuver.straight),
          LaneFault.missedTurn);
    });
    test('wrong LANE: the RIGHT move, but from a lane that does not allow it', () {
      // Went straight (as commanded) but from the left-only inner lane — you did
      // the task, just from the wrong lane.
      expect(
          verdict(
              inner: true, did: Maneuver.straight, commanded: Maneuver.straight),
          LaneFault.wrongLane);
    });
    test('wrong EXIT lane: right move, right lane, but the far lane', () {
      expect(
          verdict(
              inner: false,
              did: Maneuver.right,
              commanded: Maneuver.right,
              farExit: true),
          LaneFault.wrongExitLane);
      expect(
          verdict(
              inner: true,
              did: Maneuver.left,
              commanded: Maneuver.left,
              farExit: true),
          LaneFault.wrongExitLane);
    });
    test('priority: a missed turn dominates a wrong lane and a far exit', () {
      // Wrong lane AND wrong outcome AND far exit → reported as the missed turn.
      expect(
          verdict(
              inner: false,
              did: Maneuver.right,
              commanded: Maneuver.left,
              farExit: true),
          LaneFault.missedTurn);
    });
    test('the verdict follows the config (straight/right split, not L1)', () {
      // Split: straight legal only from inner, right only from outer.
      expect(
          IntersectionLightTile.laneVerdict(
              config: LaneConfig.straightRightSplit,
              inner: true,
              did: Maneuver.straight,
              commanded: Maneuver.straight,
              farExit: false),
          isNull);
      // Straight from the (right-only) outer lane is now a wrong-lane fault —
      // the opposite of L1, where straight is the outer lane's job.
      expect(
          IntersectionLightTile.laneVerdict(
              config: LaneConfig.straightRightSplit,
              inner: false,
              did: Maneuver.straight,
              commanded: Maneuver.straight,
              farExit: false),
          LaneFault.wrongLane);
    });
  });

  group('signalGateVerdict — signal compliance at the gate', () {
    SignalGateFault? v(SignalPhase phase, Maneuver commanded,
            {bool stoppedFirst = false, bool couldStopAtYellow = false}) =>
        IntersectionLightTile.signalGateVerdict(
            phase: phase,
            commanded: commanded,
            stoppedFirst: stoppedFirst,
            couldStopAtYellow: couldStopAtYellow);

    test('green is always clean', () {
      expect(v(SignalPhase.green, Maneuver.straight), isNull);
      expect(v(SignalPhase.green, Maneuver.left), isNull);
    });
    test('yellow faults only if you could have stopped', () {
      expect(v(SignalPhase.yellow, Maneuver.straight, couldStopAtYellow: true),
          SignalGateFault.ranYellow);
      expect(v(SignalPhase.yellow, Maneuver.straight, couldStopAtYellow: false),
          isNull);
    });
    test('red: straight/left always runs it (even stopped first)', () {
      expect(v(SignalPhase.red, Maneuver.straight, stoppedFirst: true),
          SignalGateFault.ranRed);
      expect(v(SignalPhase.red, Maneuver.left, stoppedFirst: true),
          SignalGateFault.ranRed);
    });
    test('red + right is legal ONLY after a full stop (US right-on-red)', () {
      expect(v(SignalPhase.red, Maneuver.right, stoppedFirst: true), isNull);
      // Rolled the right-on-red without stopping → runs it.
      expect(v(SignalPhase.red, Maneuver.right, stoppedFirst: false),
          SignalGateFault.ranRed);
    });
  });

  group('couldStopForYellow — the dilemma zone', () {
    test('already at/over the line → commit (cannot stop)', () {
      expect(IntersectionLightTile.couldStopForYellow(0, 100), isFalse);
      expect(IntersectionLightTile.couldStopForYellow(-10, 100), isFalse);
    });
    test('ample room → could stop (so proceeding is a fault)', () {
      expect(IntersectionLightTile.couldStopForYellow(400, 100), isTrue);
    });
    test('too close for the speed → commit (no fault)', () {
      expect(IntersectionLightTile.couldStopForYellow(40, 100), isFalse);
    });
  });

  group('TrafficLightScenario — yellow + stop-line faults', () {
    test('running a stoppable yellow fails the run (and stays failed)', () {
      final s = LaneDisciplineScenario();
      s.onYellowRun();
      expect(s.result.status, ScenarioStatus.failed);
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.failed);
    });
    test('stopping over the line fails the run', () {
      final s = LaneDisciplineScenario();
      s.onStopLineViolation();
      expect(s.result.status, ScenarioStatus.failed);
    });
    test('gunning the green into an uncleared box fails the run', () {
      final s = LaneDisciplineScenario();
      s.onGunGreen();
      expect(s.result.status, ScenarioStatus.failed);
    });
  });

  group('npcLeftCommits — NPC left-turn gap acceptance (yields at the bend)', () {
    bool c(
            {bool green = false,
            double gapToLine = 50,
            double gapToBend = 50,
            bool oncomingBlocks = false}) =>
        IntersectionLightTile.npcLeftCommits(
            green: green,
            gapToLine: gapToLine,
            gapToBend: gapToBend,
            oncomingBlocks: oncomingBlocks);

    test('past the bend it always finishes (never re-holds mid-turn)', () {
      expect(c(gapToBend: 0, oncomingBlocks: true), isTrue);
      expect(c(gapToBend: -10, green: false, oncomingBlocks: true), isTrue);
    });
    test('red short of the line holds — it does not enter the box', () {
      expect(c(green: false, gapToLine: 30), isFalse);
    });
    test('permissive green on the approach: enters on a clear gap, holds when blocked',
        () {
      expect(c(green: true, gapToLine: 30, oncomingBlocks: false), isTrue);
      expect(c(green: true, gapToLine: 30, oncomingBlocks: true), isFalse);
    });
    test('at the bend (past the line): waits for oncoming, completes when clear', () {
      // pulled in on green, oncoming still moving → keep waiting at the bend
      expect(c(green: true, gapToLine: -5, gapToBend: 10, oncomingBlocks: true),
          isFalse);
      // oncoming has stopped (e.g. phase end) → completes
      expect(c(green: false, gapToLine: -5, gapToBend: 10, oncomingBlocks: false),
          isTrue);
    });
  });

  group('leftTurnApproachCap — gentle, comfortable approach', () {
    test('eases to a HALT at the wait point when yielding (comfort decel, not a slam)',
        () {
      // Far out the cap is high (no limit); near the stop it ramps smoothly to 0.
      final far = IntersectionLightTile.leftTurnApproachCap(300, yielding: true);
      final near = IntersectionLightTile.leftTurnApproachCap(70, yielding: true);
      expect(far, greaterThan(near));
      expect(IntersectionLightTile.leftTurnApproachCap(40, yielding: true), 0.0,
          reason: 'at the setback the gentle cap is a full stop');
      // It is gentler than the hard stop curve would be (comfort 110 < hard 225).
      final brakeDist = 70 - kCarLength * 0.5 - kStopLineSetback;
      expect(near, lessThan(math.sqrt(2 * kNpcBrakeDecel * brakeDist)));
    });
    test('a CLEAR turn never drops below turn speed (it keeps flowing)', () {
      expect(IntersectionLightTile.leftTurnApproachCap(0, yielding: false),
          closeTo(kNpcTurnSpeed, 0.001));
      expect(IntersectionLightTile.leftTurnApproachCap(-20, yielding: false),
          closeTo(kNpcTurnSpeed, 0.001));
      expect(IntersectionLightTile.leftTurnApproachCap(200, yielding: false),
          greaterThan(kNpcTurnSpeed));
    });
  });

  group('left-turn yield waits at the BEND, in the junction', () {
    // The NPC left-turner pulls INTO the junction and yields at the bend (the arc
    // apex, nosed into the curve), like a real left-turner — not back at the stop
    // line. Drives the REAL _applySignalToNpcs via updateNpcSensors.

    // seed 0 (origin placement) → N–S starts GREEN; updateNpcSensors does not tick
    // the signal, so it stays green for the call.
    IntersectionLightTile placeGreen() =>
        IntersectionLightTile(config: LaneConfig.l1)
          ..place(worldPosition: Vector2.zero(), orientation: 0.0);

    // Place the turner on its spline so it's `gapToBend` (arc-length) short of the
    // bend — past the stop line, in the junction. Uses startDistance so the car's
    // distanceTravelled matches its position (gapToBend reads off distanceTravelled).
    NpcCar southLeftNearBend(IntersectionLightTile tile, {double gapToBend = 60}) {
      final (spline, laneIndex) = tile.debugSouthLeftTurner;
      // Mirror the production bend point: the arc apex (nearest the box centre),
      // nudged a half-car deeper.
      final bendDist =
          spline.distanceAtNearest(Vector2(600, 820)) + kCarLength * 0.5;
      final npc = NpcCar(
          definition: CarVariants.all.first, profileSpeed: kmhToUnits(40));
      npc.laneIndex = laneIndex;
      npc.assignSpline(spline,
          startDistance: bendDist - gapToBend, worldOffset: Vector2.zero());
      npc.position = npc.splinePosition; // assignSpline sets distanceTravelled, not position
      npc.speed = kmhToUnits(40);
      return npc;
    }

    test('holds at the bend for the oncoming player (in the junction, yielding)', () {
      final tile = placeGreen();
      final turner = southLeftNearBend(tile);
      tile.npcs
        ..clear()
        ..add(turner);
      // Confirm it's past the stop line, IN the junction box (not back on the line).
      expect(tile.worldToLocal(turner.position).y, greaterThan(660),
          reason: 'it has pulled into the box');
      // The player is the northbound through — moving, in the north approach.
      final player = PlayerCar()
        ..position = tile.localToWorld(Vector2(640, 1100))
        ..speed = kmhToUnits(40);

      tile.updateNpcSensors(1 / 60, player, tile.npcs, const []);

      expect(turner.brain.hasRightOfWay, isFalse,
          reason: 'it yields to the oncoming player from the bend');
      expect(turner.brain.stopTargetDistance, isNotNull,
          reason: 'it holds — a stop target is set');
      expect(turner.brain.stopTargetDistance, closeTo(60, 1.0),
          reason: 'the hold target is the bend (gapToBend≈60), in the junction');
      expect(turner.brain.speedCap, isNotNull,
          reason: 'a comfortable approach cap is set, not an uncapped slam');
    });

    test('with oncoming clear it completes the turn (does NOT freeze)', () {
      final tile = placeGreen();
      final turner = southLeftNearBend(tile);
      tile.npcs
        ..clear()
        ..add(turner);
      // No oncoming — the player is off the approach and stopped.
      final player = PlayerCar()..speed = 0;

      tile.updateNpcSensors(1 / 60, player, tile.npcs, const []);

      expect(turner.brain.hasRightOfWay, isTrue,
          reason: 'a clear gap → the turner completes, never stuck');
    });

    // Targeted release: once the oncoming has passed the box centre (and thus the
    // turn's crossing point), the turner goes — it does NOT wait for the car to
    // fully leave the box.
    NpcCar bendTurnerVsPlayerAtY(IntersectionLightTile tile, double playerY) {
      final turner = southLeftNearBend(tile);
      tile.npcs
        ..clear()
        ..add(turner);
      final player = PlayerCar()
        ..position = tile.localToWorld(Vector2(640, playerY))
        ..speed = kmhToUnits(40); // straight-through (no spline → committed straight)
      tile.updateNpcSensors(1 / 60, player, tile.npcs, const []);
      return turner;
    }

    test('a straight player PAST the centre releases the turner (no dead waiting)',
        () {
      // y=700 < centre (820): in the box, past the crossing → released.
      expect(bendTurnerVsPlayerAtY(placeGreen(), 700).brain.hasRightOfWay, isTrue,
          reason: 'oncoming has cleared the crossing → keep going');
    });
    test('a straight player in the box but BEFORE the centre still holds it', () {
      // y=900 > centre (820): in the box, not yet at the crossing → still yields.
      expect(bendTurnerVsPlayerAtY(placeGreen(), 900).brain.hasRightOfWay, isFalse,
          reason: 'oncoming has not reached the crossing yet → hold');
    });
  });

  group('pedestrian half-rule — a far ped on the far half does not stop you', () {
    // US "half-rule": yield to a ped in your half (or close enough to be in
    // danger), NOT one still two lanes away on the wide 2-lane crossing. Drives the
    // real _pedStopOnPath along the player's straight spline (x=640) across the
    // south zebra (band centre y=cy+218=1038); the player sits ~120 short so the
    // forward scan reaches the band.
    final tile = IntersectionLightTile(config: LaneConfig.l1)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final spline = tile.approach(inner: true); // player's straight, x=640
    const bandY = 820.0 + 218.0; // south zebra centre
    final travelled = (1640.0 - bandY) - 120.0;

    Pedestrian pedAt(double x, {required double angle}) {
      final ped = Pedestrian(
        crossingPath: Spline([Vector2(0, bandY), Vector2(1200, bandY)]),
        walkSpeed: 20,
        color: const Color(0xFF1565C0),
        skinColor: const Color(0xFFF1C9A5),
        hairColor: const Color(0xFF20140A),
      );
      ped.position = Vector2(x, bandY); // tile at origin → world == local
      ped.angle = angle; // 0 = +x (east, toward the x=640 lane); pi = west
      return ped;
    }

    test('FAR half + walking toward you → no stop (the 2-lane "too much" case)', () {
      // x=460 is ~180px left of the lane — beyond the ~120 danger zone — walking
      // east at it. Far half → keep going.
      expect(tile.pedStopAlong(spline, travelled, [pedAt(460, angle: 0)]), isNull,
          reason: 'a ped two lanes away on the far half is not your danger zone');
    });

    test('within your half + walking toward you → stop', () {
      // x=560 is ~80px from the lane — inside the zone — walking east at it.
      expect(tile.pedStopAlong(spline, travelled, [pedAt(560, angle: 0)]), isNotNull,
          reason: 'close to your half, walking at your path → yield');
    });

    test('right at your path → stop regardless of facing (imminent)', () {
      // x=625 is ~15px from the lane — within kPedYieldLateral — even facing away.
      expect(
          tile.pedStopAlong(spline, travelled, [pedAt(625, angle: math.pi)]),
          isNotNull,
          reason: 'a ped on your lane stops you even if facing away');
    });
  });

  group('NPC left turns only on non-opposing approaches (no head-on pair)', () {
    // The opposing-left stagger is GONE; instead two FACING left-turners can never
    // exist. NPC lefts are offered on north + east only, so south/west inner lanes
    // are straight-only — the head-on conflict is removed by construction, which is
    // what licenses deleting the wait-rule. (_Heading order [north, east, south,
    // west]; group index k*2+lane, lane 0 = inner. Inner lane is [straight] or
    // [straight, left], so length 2 ⇔ a left is offered.)
    final tile = IntersectionLightTile(config: LaneConfig.l1)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);

    for (final a in const [
      (name: 'north', k: 0, left: true), // the player's own approach
      (name: 'east', k: 1, left: true), // the cross axis
      (name: 'south', k: 2, left: false), // opposite north → no left
      (name: 'west', k: 3, left: false), // opposite east → no left
    ]) {
      test('${a.name} inner lane ${a.left ? "offers" : "has no"} a left turn', () {
        expect(tile.npcLanes[a.k * 2].length, a.left ? 2 : 1,
            reason: a.left
                ? '${a.name} offers a left (its opposite never does → no pair)'
                : '${a.name} is straight-only so no facing-left pair can form');
      });
    }
  });
}
