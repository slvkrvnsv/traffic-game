import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/tiles/scenarios/scenario_base.dart';
import 'package:traffic_game/tiles/scenarios/stop_sign_scenario.dart';
import 'package:traffic_game/tiles/scenarios/traffic_light_scenario.dart';
import 'package:traffic_game/tiles/scenarios/scenario_registry.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/traffic_signal.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Scenario grading (pure) — mirrors stop_sign_test: a clean run-through on
  // green is a pass, crossing on red fails the task (non-fatal), a crash fails.
  // ---------------------------------------------------------------------------
  group('TrafficLightScenario', () {
    test('a clean clear (no violation) passes', () {
      final s = TrafficLightScenario();
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.passed);
    });

    test('running a red fails the task (non-fatal — recorded, not game over)',
        () {
      final s = TrafficLightScenario();
      s.onRedLightViolation();
      expect(s.result.status, ScenarioStatus.failed);
      expect(s.result.reason, contains('red light'));

      // Clearing the box afterwards must not flip a failed run to passed.
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.failed);
    });

    test('a crash fails the scenario', () {
      final s = TrafficLightScenario();
      s.onCollision('npc_car');
      expect(s.result.status, ScenarioStatus.failed);
      expect(s.result.reason, contains('npc_car'));
    });

    test('turning left without yielding fails the task', () {
      final s = TrafficLightScenario();
      s.onYieldViolation(40);
      expect(s.result.status, ScenarioStatus.failed);
      expect(s.result.reason, contains('yielding'));
      // A later safe-clear must not flip a failed run to passed.
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.failed);
    });

    test('blocking the intersection fails the task', () {
      final s = TrafficLightScenario();
      s.onBlockedIntersection();
      expect(s.result.status, ScenarioStatus.failed);
      expect(s.result.reason, contains('Blocked the intersection'));
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.failed);
    });

    test('reset re-arms the pass gate', () {
      final s = TrafficLightScenario();
      s.onRedLightViolation();
      expect(s.result.status, ScenarioStatus.failed);
      s.reset();
      expect(s.result.status, ScenarioStatus.ongoing);
      s.onSafelyCleared();
      expect(s.result.status, ScenarioStatus.passed);
    });

    test('the 4-way intersection can be dressed as a stop OR a light', () {
      final seen = <Type>{};
      // forTile rolls randomly across the registered variants; over many draws
      // both controls must appear (the registry lists exactly these two).
      for (var i = 0; i < 200; i++) {
        seen.add(ScenarioRegistry.forTile(TileType.intersection4way).runtimeType);
      }
      expect(seen, containsAll(<Type>{StopSignScenario, TrafficLightScenario}));
    });
  });

  // ---------------------------------------------------------------------------
  // Signal controller — the safety invariant a real signal must guarantee:
  // two conflicting approaches are never green together, and there is always an
  // all-red clearance between swaps. Walked across a full cycle.
  // ---------------------------------------------------------------------------
  group('TrafficSignalController', () {
    SignalPhase ns(TrafficSignalController c) => c.phaseFor(northSouth: true);
    SignalPhase ew(TrafficSignalController c) => c.phaseFor(northSouth: false);

    test('conflicting approaches are never green at the same time', () {
      final c = TrafficSignalController();
      // Fine-grained walk across two full cycles.
      var sawNsGreen = false, sawEwGreen = false, sawAllRed = false;
      for (var i = 0; i < 2000; i++) {
        final g1 = ns(c) == SignalPhase.green;
        final g2 = ew(c) == SignalPhase.green;
        expect(g1 && g2, isFalse,
            reason: 'N–S and E–W must never both show green');
        sawNsGreen |= g1;
        sawEwGreen |= g2;
        sawAllRed |= ns(c) == SignalPhase.red && ew(c) == SignalPhase.red;
        c.tick(0.05);
      }
      // Both groups actually get a turn, and an all-red window exists.
      expect(sawNsGreen, isTrue);
      expect(sawEwGreen, isTrue);
      expect(sawAllRed, isTrue, reason: 'there must be an all-red clearance');
    });

    test('green is always followed by yellow before red (no green→red jump)',
        () {
      final c = TrafficSignalController();
      var prev = ns(c);
      for (var i = 0; i < 2000; i++) {
        c.tick(0.05);
        final now = ns(c);
        if (prev == SignalPhase.green && now != SignalPhase.green) {
          expect(now, SignalPhase.yellow,
              reason: 'green must drop to yellow, never straight to red');
        }
        if (prev == SignalPhase.red && now != SignalPhase.red) {
          expect(now, SignalPhase.green,
              reason: 'red clears to green');
        }
        prev = now;
      }
    });

    test('the seed only offsets the start phase, not the timing', () {
      final a = TrafficSignalController(seed: 0);
      final b = TrafficSignalController(seed: 12345);
      // Different seeds generally start in different phases (so neighbouring
      // lights aren't synchronised) — but both still cycle through all phases.
      final phasesB = <SignalPhase>{};
      for (var i = 0; i < 2000; i++) {
        phasesB.add(b.phaseFor(northSouth: true));
        b.tick(0.05);
      }
      expect(phasesB,
          containsAll(SignalPhase.values),
          reason: 'a seeded controller still visits every phase');
      // `a` is a distinct instance with its own phase — sanity that construction
      // with a seed doesn't throw and yields a valid phase.
      expect(SignalPhase.values, contains(a.phaseFor(northSouth: false)));
    });
  });

  // ---------------------------------------------------------------------------
  // Commit & clear — a car that has crossed the line must NOT be braked to a
  // stop in the junction mouth when the light turns yellow/red mid-crossing.
  // This is the integration seam the pure scenario/phase tests skip; it walks a
  // vehicle from before the line through it on a non-green and asserts the light
  // stop releases the instant the gap goes non-positive (never negative).
  // ---------------------------------------------------------------------------
  group('IntersectionTile.signalStopTarget (commit & clear)', () {
    test('green never imposes a light stop', () {
      expect(IntersectionTile.signalStopTarget(true, 120, null), isNull);
      expect(IntersectionTile.signalStopTarget(true, -5, null), isNull);
    });

    test('a car still BEFORE the line on a non-green holds at it', () {
      expect(IntersectionTile.signalStopTarget(false, 80, null), 80);
    });

    test('a car AT or PAST the line on a non-green commits (no light stop)', () {
      // The freeze bug: a negative gap must NOT become a stop target.
      expect(IntersectionTile.signalStopTarget(false, 0, null), isNull);
      expect(IntersectionTile.signalStopTarget(false, -1, null), isNull);
      expect(IntersectionTile.signalStopTarget(false, -102, null), isNull);
    });

    test('stepping through the line on red never yields a negative stop target',
        () {
      // Walk the gap from well before the line to well past it, light red the
      // whole way. The stop target holds at the (positive) gap until the line,
      // then releases — it is never negative (which would freeze the car).
      for (double gap = 120; gap >= -120; gap -= 4) {
        final s = IntersectionTile.signalStopTarget(false, gap, null);
        if (gap > 0) {
          expect(s, gap, reason: 'holds at the line while approaching');
        } else {
          expect(s, isNull, reason: 'commits & clears once at/past the line');
        }
        if (s != null) {
          expect(s, greaterThan(0), reason: 'a stop target is never negative');
        }
      }
    });

    test('a pedestrian ahead still stops a committed car (nearer wins)', () {
      // Past the line (committed → no light stop) but a pedestrian is on the
      // exit crossing 30u ahead: the car still holds for the crossing.
      expect(IntersectionTile.signalStopTarget(false, -10, 30), 30);
      // Before the line, the nearer of the two holds.
      expect(IntersectionTile.signalStopTarget(false, 80, 30), 30);
      expect(IntersectionTile.signalStopTarget(false, 20, 60), 20);
    });
  });

  // ---------------------------------------------------------------------------
  // Pedestrians obey the light: step off the curb only when the road they cross
  // is RED (parallel traffic green = the walk phase). The band→road→phase
  // mapping is the inversion-prone bit — pin it so a later edit can't silently
  // send peds out in front of moving traffic.
  // ---------------------------------------------------------------------------
  group('IntersectionTile.pedMustHoldForSignal (peds obey the light)', () {
    // Geometry: _halfBox = 80. `along` is the ped's position along its crossing
    // axis from the tile centre; `sign` the travel direction along it.
    // "approaching" = before the near carriageway edge (along·sign < -80);
    // "committed" = at/past it (>= -80) → must finish crossing.
    const approaching = -90.0; // eastbound (sign +1): -90 < -80 → not committed
    const committed = 82.0; //    eastbound (sign +1):  82 >= -80 → committed

    test('not stepping onto a crossing (band -1) → never held', () {
      expect(
          IntersectionTile.pedMustHoldForSignal(
              -1, approaching, 1.0, SignalPhase.green, SignalPhase.green),
          isFalse);
    });

    test('a committed ped finishes crossing — never re-held (the exit bug)', () {
      // Entered on a walk; the light flips to don't-walk as it leaves the far
      // side. It must keep going, not freeze at the edge of the zebra box.
      expect(
          IntersectionTile.pedMustHoldForSignal(
              0, committed, 1.0, SignalPhase.green, SignalPhase.red),
          isFalse);
      // Same, walking the other way (sign -1, exiting toward -x).
      expect(
          IntersectionTile.pedMustHoldForSignal(
              0, -committed, -1.0, SignalPhase.green, SignalPhase.red),
          isFalse);
    });

    test('south/north crossings track the N–S road phase', () {
      for (final band in [0, 1]) {
        // crosses the N–S road → hold while N–S moves, walk on N–S red.
        expect(
            IntersectionTile.pedMustHoldForSignal(
                band, approaching, 1.0, SignalPhase.green, SignalPhase.red),
            isTrue,
            reason: 'band $band: N–S green → cars moving → hold');
        expect(
            IntersectionTile.pedMustHoldForSignal(
                band, approaching, 1.0, SignalPhase.yellow, SignalPhase.red),
            isTrue,
            reason: 'band $band: N–S yellow → still clearing → hold');
        expect(
            IntersectionTile.pedMustHoldForSignal(
                band, approaching, 1.0, SignalPhase.red, SignalPhase.green),
            isFalse,
            reason: 'band $band: N–S red → cars stopped → walk');
      }
    });

    test('east/west crossings track the E–W road phase (not inverted)', () {
      for (final band in [2, 3]) {
        // crosses the E–W road → hold while E–W moves, walk on E–W red.
        expect(
            IntersectionTile.pedMustHoldForSignal(
                band, approaching, 1.0, SignalPhase.red, SignalPhase.green),
            isTrue,
            reason: 'band $band: E–W green → cars moving → hold');
        expect(
            IntersectionTile.pedMustHoldForSignal(
                band, approaching, 1.0, SignalPhase.green, SignalPhase.red),
            isFalse,
            reason: 'band $band: E–W red → cars stopped → walk');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Permissive-left fail-to-yield: turning across oncoming traffic faults only
  // when it forces the oncoming car to brake HARD. The boundary that matters —
  // turning into a genuine gap (far car) must NOT fault — proves this isn't just
  // "oncoming exists". kReactMinSpeed = 60 u/s; the hard-brake bar ≈ 292 u/s².
  // ---------------------------------------------------------------------------
  group('IntersectionTile.leftTurnCutsOffOncoming', () {
    test('close + fast oncoming → cut off (fault)', () {
      // 50 km/h (250 u/s), 50u gap → a_req ≈ 1950 ≫ bar.
      expect(IntersectionTile.leftTurnCutsOffOncoming(250, 50), isTrue);
    });

    test('a genuine gap → NOT cut off (turning into a gap is legal)', () {
      // Same speed, 400u gap → a_req ≈ 85 < bar. The case that proves the fault
      // isn't faulting mere presence of oncoming traffic.
      expect(IntersectionTile.leftTurnCutsOffOncoming(250, 400), isFalse);
    });

    test('slow / barely-moving oncoming → never cut off', () {
      // Below kReactMinSpeed: a crawling car isn't "cut off" however close.
      expect(IntersectionTile.leftTurnCutsOffOncoming(30, 20), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // "Don't block the box" arithmetic: a vehicle short of the far edge can only
  // enter if a stopped car ahead leaves room for its whole body past the box.
  // kCarLength = 52, kNpcStandingGap = 34 → needs gapToFarEdge + 86 of room.
  // ---------------------------------------------------------------------------
  group('IntersectionTile.cannotClearBox', () {
    test('nothing stopped ahead → can always clear', () {
      expect(IntersectionTile.cannotClearBox(200, null), isFalse);
    });

    test('a stopped car with room past the box → can clear', () {
      // 200 + 86 = 286 needed; 300 of room → fits.
      expect(IntersectionTile.cannotClearBox(200, 300), isFalse);
    });

    test('a stopped car too close → cannot clear (hold before the box)', () {
      // 250 < 286 → no room for the body past the far edge.
      expect(IntersectionTile.cannotClearBox(200, 250), isTrue);
    });

    test('already past the far edge → committed, never held', () {
      expect(IntersectionTile.cannotClearBox(-5, 10), isFalse);
      expect(IntersectionTile.cannotClearBox(0, 10), isFalse);
    });
  });
}
