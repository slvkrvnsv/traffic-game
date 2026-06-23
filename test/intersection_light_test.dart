import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/tiles/traffic_signal.dart';
import 'package:traffic_game/tiles/definitions/intersection_light_tile.dart';
import 'package:traffic_game/tiles/scenarios/lane_discipline_scenario.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';

void main() {
  group('geometry — turn splines land in the right lanes, never off-tile', () {
    IntersectionLightTile place() => IntersectionLightTile()
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);

    // Tile is 1200 wide × 1640 tall, box centred at (600, 820). Lanes: N-bound
    // 640/720, exits — west-bound 780/700, east-bound 860/940, south edge 1640.
    const w = 1200.0, h = 1640.0, cy = 820.0;

    test('entering the outer lane commands a left into the inner lane', () {
      final tile = place();
      // Player centre nearest the OUTER approach lane (720) → must take inner.
      tile.bindPlayerEntry(Vector2(720, h));
      expect(tile.commandedManeuver, Maneuver.left);
      expect(tile.playerPaths.length, 2);

      final inner = tile.playerPaths[0];
      final outer = tile.playerPaths[1];
      // Approaches start in the two parallel lanes (at the south edge), 80u apart.
      expect(inner.evaluate(0.0).x, closeTo(640, 1));
      expect(inner.evaluate(0.0).y, closeTo(h, 1));
      expect(outer.evaluate(0.0).x, closeTo(720, 1));
      // Left exits west into the two west-bound lanes (inner cy-40 / outer cy-120).
      expect(inner.evaluate(1.0).x, closeTo(0, 2));
      expect(inner.evaluate(1.0).y, closeTo(cy - 40, 2));
      expect(outer.evaluate(1.0).y, closeTo(cy - 120, 2));
      // The legal lane for a left is the inner one (index 0).
      expect(tile.exitAnchor.x, closeTo(0, 1));
      expect(tile.exitDirection.x, closeTo(-1, 1e-9));
    });

    test('entering the inner lane commands straight/right, legal lane = outer', () {
      final tile = place();
      tile.bindPlayerEntry(Vector2(640, h));
      expect(tile.commandedManeuver, anyOf(Maneuver.straight, Maneuver.right));
      // The outer lane is the legal one; for a right turn it exits east.
      final outer = tile.playerPaths[1];
      if (tile.commandedManeuver == Maneuver.right) {
        expect(outer.evaluate(1.0).x, closeTo(w, 2));
        expect(outer.evaluate(1.0).y, closeTo(cy + 120, 2));
      } else {
        expect(outer.evaluate(1.0).x, closeTo(720, 2));
        expect(outer.evaluate(1.0).y, closeTo(0, 2));
      }
    });

    test('no player or NPC path ever leaves the tile bounds', () {
      for (final entry in [Vector2(640, h), Vector2(720, h)]) {
        final tile = place();
        tile.bindPlayerEntry(entry);
        final all = [...tile.playerPaths, ...tile.npcPaths];
        for (final s in all) {
          for (int i = 0; i <= 30; i++) {
            final p = s.evaluate(i / 30);
            expect(p.x, inInclusiveRange(-6, w + 6));
            expect(p.y, inInclusiveRange(-6, h + 6));
          }
        }
      }
    });

    test('there are 8 NPC lane groups (2 lanes × 4 approaches)', () {
      final tile = place();
      expect(tile.npcLanes.length, 8);
    });

    test('player paths follow the BOUND maneuver even if read before binding', () {
      final tile = place();
      // Simulate the debug spline overlay reading playerPaths a frame before the
      // player hands off onto the tile (i.e. before bindPlayerEntry runs).
      expect(tile.playerPaths.length, 2);
      // Now the player enters the outer lane → the bound task is a LEFT turn.
      tile.bindPlayerEntry(Vector2(720, h));
      expect(tile.commandedManeuver, Maneuver.left);
      // The path must be a real left turn (exits WEST at x≈0), not a stale straight.
      expect(tile.playerPaths[0].evaluate(1.0).x, closeTo(0, 2));
      expect(tile.playerPaths[0].evaluate(1.0).y, closeTo(cy - 40, 2));
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
