import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/tiles/traffic_signal.dart';
import 'package:traffic_game/tiles/tile_base.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/scenarios/lane_discipline_scenario.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';

void main() {
  group('geometry — approach lanes run straight, turn branches land right', () {
    IntersectionLightTile place() => IntersectionLightTile()
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

    test('the commanded maneuver is late-bound to force a lane change', () {
      // Entered outer → must move to inner → commanded LEFT.
      expect(
          (place()..bindPlayerEntry(Vector2(720, h))).commandedManeuver,
          Maneuver.left);
      // Entered inner → must move to outer → commanded straight or right.
      expect(
          (place()..bindPlayerEntry(Vector2(640, h))).commandedManeuver,
          anyOf(Maneuver.straight, Maneuver.right));
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
    IntersectionLightTile place() => IntersectionLightTile()
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

    test('crossing a tap while leaning takes the turn; neutral or wrong-way stays straight',
        () {
      final tile = place();
      final spine = tile.approach(inner: true);
      final branches = tile.playerBranches(spine);
      final nearLeft = tile.branch(inner: true, m: Maneuver.left);
      final farLeft = tile.farBranch(m: Maneuver.left);
      final dNear = spine.distanceAtNearest(nearLeft.evaluate(0.0)); // ~780
      final dFar = spine.distanceAtNearest(farLeft.evaluate(0.0)); // ~860
      // Cross the NEAR tap leaning LEFT → near-left; neutral or right → stay straight.
      expect(TileManager.branchToTake(spine, branches, dNear - 8, dNear + 8, -1),
          same(nearLeft));
      expect(
          TileManager.branchToTake(spine, branches, dNear - 8, dNear + 8, 0), isNull);
      expect(
          TileManager.branchToTake(spine, branches, dNear - 8, dNear + 8, 1), isNull);
      // Skip the near tap (no lean there), then lean LEFT across the FAR tap → far-left.
      expect(TileManager.branchToTake(spine, branches, dFar - 8, dFar + 8, -1),
          same(farLeft));
      // Between taps with a lean held but nothing crossed → nothing fires.
      expect(TileManager.branchToTake(spine, branches, dNear + 8, dFar - 8, -1), isNull);
      // Outer mirror: lean RIGHT across the near-right tap → near-right.
      final outer = tile.approach(inner: false);
      final outBranches = tile.playerBranches(outer);
      final nearRight = tile.branch(inner: false, m: Maneuver.right);
      final dNR = outer.distanceAtNearest(nearRight.evaluate(0.0));
      expect(TileManager.branchToTake(outer, outBranches, dNR - 8, dNR + 8, 1),
          same(nearRight));
      expect(
          TileManager.branchToTake(outer, outBranches, dNR - 8, dNR + 8, -1), isNull);
    });
  });

  group('laneIsLegal — the lane-discipline rule (L1 layout)', () {
    test('left turn is legal only from the inner (centre-side) lane', () {
      expect(IntersectionLightTile.laneIsLegal(inner: true, m: Maneuver.left), isTrue);
      expect(IntersectionLightTile.laneIsLegal(inner: false, m: Maneuver.left), isFalse);
    });
    test('straight and right are legal only from the outer (curb) lane', () {
      expect(IntersectionLightTile.laneIsLegal(inner: false, m: Maneuver.straight), isTrue);
      expect(IntersectionLightTile.laneIsLegal(inner: true, m: Maneuver.straight), isFalse);
      expect(IntersectionLightTile.laneIsLegal(inner: false, m: Maneuver.right), isTrue);
      expect(IntersectionLightTile.laneIsLegal(inner: true, m: Maneuver.right), isFalse);
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
  });
}
