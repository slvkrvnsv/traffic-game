import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';
import 'package:traffic_game/tiles/scenarios/stop_sign_scenario.dart';
import 'package:traffic_game/tiles/scenarios/scenario_registry.dart';
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

  test('the registry dresses the 4-way intersection with StopSignScenario', () {
    final s = ScenarioRegistry.forTile(TileType.intersection4way);
    expect(s, isA<StopSignScenario>());
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
}
