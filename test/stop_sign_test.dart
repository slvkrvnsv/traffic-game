import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';
import 'package:traffic_game/tiles/scenarios/stop_sign_scenario.dart';
import 'package:traffic_game/tiles/scenarios/scenario_registry.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';

/// US all-way STOP grading: the pass condition is a *complete* stop, so a
/// rolling stop fails even though the European yield tile would let it pass.
void main() {
  test('a full stop then a clean clear passes', () {
    final s = StopSignScenario();
    // No violation reported by the tile == a full stop was credited.
    s.onSafelyCleared();
    expect(s.result.status, ScenarioStatus.passed);
  });

  test('a rolling stop fails the task (non-fatal — recorded, not game over)',
      () {
    final s = StopSignScenario();
    s.onStopSignViolation(7); // crawled at 7 km/h, never stopped
    expect(s.result.status, ScenarioStatus.failed);
    expect(s.result.reason, contains('complete stop'));

    // Clearing the box afterwards must not flip a failed run to passed.
    s.onSafelyCleared();
    expect(s.result.status, ScenarioStatus.failed);
  });

  test('pulling out without giving way fails the task', () {
    final s = StopSignScenario();
    s.onYieldViolation(20);
    expect(s.result.status, ScenarioStatus.failed);
    expect(s.result.reason, contains('right of way'));
  });

  test('a crash fails the scenario', () {
    final s = StopSignScenario();
    s.onCollision('npc_car');
    expect(s.result.status, ScenarioStatus.failed);
    expect(s.result.reason, contains('npc_car'));
  });

  test('blocking the intersection fails the task', () {
    final s = StopSignScenario();
    s.onBlockedIntersection();
    expect(s.result.status, ScenarioStatus.failed);
    expect(s.result.reason, contains('Blocked the intersection'));
  });

  test('reset returns the scenario to ongoing and re-arms the pass gate', () {
    final s = StopSignScenario();
    s.onStopSignViolation(5);
    expect(s.result.status, ScenarioStatus.failed);
    s.reset();
    expect(s.result.status, ScenarioStatus.ongoing);
    // A clean clear after reset passes again (the violation latch cleared).
    s.onSafelyCleared();
    expect(s.result.status, ScenarioStatus.passed);
  });

  test('the 4-way intersection still offers the all-way-stop variant', () {
    // The intersection is now dressed as a stop OR a traffic light, rolled
    // randomly (see ScenarioRegistry), so a single draw is no longer
    // deterministic — but the all-way-stop variant must still be offered. (The
    // traffic-light side of the same seam is covered in traffic_light_test.)
    final drawn = [
      for (var i = 0; i < 200; i++)
        ScenarioRegistry.forTile(TileType.intersection4way),
    ];
    expect(drawn.any((s) => s is StopSignScenario), isTrue);
  });

  // The all-way-stop arbiter (first-to-stop-first-to-go). These exercise the
  // pure release logic that guarantees the intersection can never dead-lock.
  group('all-way-stop release order', () {
    // Symmetric "everything conflicts with everything" predicate.
    bool allConflict(Object a, Object b) => true;
    // No two movements conflict.
    bool noneConflict(Object a, Object b) => false;

    test('a fully-conflicting group releases exactly the earliest ticket', () {
      final out = IntersectionTile.computeReleases(
          ['A', 'B', 'C', 'D'], <Object>{}, allConflict);
      expect(out, {'A'}, reason: 'only the first to stop may go');
    });

    test('once the leader clears, the next-earliest is released', () {
      // A has driven on (no longer a waiter, not in the conflict set).
      final out = IntersectionTile.computeReleases(
          ['B', 'C', 'D'], <Object>{}, allConflict);
      expect(out, {'B'});
    });

    test('non-conflicting movements all proceed together', () {
      final out = IntersectionTile.computeReleases(
          ['A', 'B', 'C', 'D'], <Object>{}, noneConflict);
      expect(out, {'A', 'B', 'C', 'D'});
    });

    test('a waiter is blocked only by a conflicting car already going', () {
      // A conflicts with C only. Order A,B,C. Nobody going yet.
      bool conflicts(Object a, Object b) =>
          {a, b}.containsAll({'A', 'C'});
      final out = IntersectionTile.computeReleases(
          ['A', 'B', 'C'], <Object>{}, conflicts);
      expect(out, {'A', 'B'}, reason: 'C must yield to A; B is independent');
    });

    test('a car already in the box holds back its conflicting waiters', () {
      final out = IntersectionTile.computeReleases(
          ['B', 'C'], <Object>{'A'}, allConflict);
      expect(out, {'A'}, reason: 'box occupied — no conflicting waiter enters');
    });

    test('any conflicting set always releases at least one (no dead-lock)', () {
      for (final order in [
        ['A', 'B', 'C', 'D'],
        ['D', 'C', 'B', 'A'],
        ['C', 'A', 'D', 'B'],
      ]) {
        final out = IntersectionTile.computeReleases(
            order, <Object>{}, allConflict);
        expect(out, {order.first},
            reason: 'the lowest-ticket (list-head) car proceeds for $order');
      }
    });

    // A car frozen for a pedestrian at its line steps out of the contest: it's
    // removed from the waiters AND not counted as a blocker, so a conflicting
    // cross car flows past instead of waiting on a car that won't move.
    test('a pedestrian-yielding car releases the cross car it would block', () {
      // A (earliest ticket) conflicts with B. Normally A wins and B waits.
      bool conflicts(Object a, Object b) => {a, b}.containsAll({'A', 'B'});
      final blocked = IntersectionTile.computeReleases(
          ['A', 'B'], <Object>{}, conflicts);
      expect(blocked, {'A'}, reason: 'baseline: B yields to A');

      // A is ped-yielding → dropped from waiters and never a blocker. B flows.
      final freed = IntersectionTile.computeReleases(
          ['B'], <Object>{}, conflicts);
      expect(freed, {'B'},
          reason: 'A is frozen for a pedestrian (box free) — B proceeds');
    });

    // ARRIVAL ORDER over a blocked senior: a later car must NOT take its turn
    // while an earlier car it conflicts with is still waiting — even if that
    // senior is itself held up by a third car the latecomer doesn't conflict
    // with. This is the "waved through ahead of the car that came first" bug:
    // D is crossing the box; O arrived before the player and conflicts with D
    // (so O is stuck); the player P arrived last, is clear of D, but conflicts
    // with O. P must wait for O, not leapfrog it.
    test('a late car does not leapfrog an earlier car blocked by a third', () {
      bool conflicts(Object a, Object b) {
        final s = {a, b};
        return s.containsAll({'O', 'D'}) || s.containsAll({'P', 'O'});
      }
      final out = IntersectionTile.computeReleases(['O', 'P'], {'D'}, conflicts);
      expect(out, {'D'},
          reason: 'P must wait for the earlier O, not pass it while it is held');
    });

    // The flip side: arrival order only gates CONFLICTING cars. A latecomer
    // whose path crosses nobody still waiting proceeds — independent movements
    // are never queued behind an unrelated blocked car (no over-blocking).
    test('a later car still goes when it conflicts with no waiting senior', () {
      bool conflicts(Object a, Object b) => {a, b}.containsAll({'O', 'D'});
      final out = IntersectionTile.computeReleases(['O', 'P'], {'D'}, conflicts);
      expect(out, {'D', 'P'},
          reason: 'P conflicts with nobody waiting → not gated by the queue');
    });
  });

  // The scope decision for "stop blocking cross traffic": ONLY a car at/behind
  // its own stop line and held by a pedestrian yields its turn. A car in the box
  // OR one that has rolled past its line (both atOwnLine == false) keeps its turn
  // — it occupies / is committed to the intersection — even with a ped ahead.
  group('isPedYieldingAtEntry scope', () {
    test('at the line + a pedestrian hold = yielding at entry', () {
      expect(IntersectionTile.isPedYieldingAtEntry(true, 42.0), isTrue);
    });
    test('not at the line (in box / past line) is never flagged', () {
      expect(IntersectionTile.isPedYieldingAtEntry(false, 42.0), isFalse);
      expect(IntersectionTile.isPedYieldingAtEntry(false, null), isFalse);
    });
    test('at the line with a clear path is not yielding', () {
      expect(IntersectionTile.isPedYieldingAtEntry(true, null), isFalse);
    });
  });

  // The premise of the deferred fail-to-yield (_checkAllStopYield): the player's
  // conflict is judged from the path it actually STEERED, not the through-spine
  // it still sits on at the stop line. Heading { north=0, east=1, south=2,
  // west=3 } — the player approaches from the south going NORTH (lane 0 = the
  // unrotated player geometry); an NPC entering from the player's RIGHT travels
  // WEST (lane 3). The reported bug: a right-turning player faulted for failing
  // to yield to that NPC's LEFT turn — two arcs that never cross.
  group('fail-to-yield conflict geometry (player vs the approach on its right)', () {
    test('a right turn clears every movement from the right; straight does not',
        () {
      final tile = IntersectionTile(maneuver: Maneuver.right);
      // All-way stop keeps all three movements, so [maneuver.index] picks the
      // right spline (the light variant drops left and would misalign).
      expect(tile.npcLanes[3].length, 3);

      const player = 0; // north (player geometry)
      const fromRight = 3; // west (enters from the player's right)

      // At the line the steered turn isn't taken yet, so the player reads as
      // going STRAIGHT — which DOES cross the right-side left turn. Judging the
      // fault there (the old behaviour) is the false positive.
      expect(
        tile.npcMovementsConflict(
            player, Maneuver.straight, fromRight, Maneuver.left),
        isTrue,
        reason: 'a straight player crosses the left-turner — the over-report',
      );
      // The movement actually commanded/steered: a right turn hugs the near
      // corner and crosses NOTHING from the approach on its right.
      for (final nm in Maneuver.values) {
        expect(
          tile.npcMovementsConflict(player, Maneuver.right, fromRight, nm),
          isFalse,
          reason: 'a right turn should clear $nm from the right',
        );
      }
    });
  });
}
