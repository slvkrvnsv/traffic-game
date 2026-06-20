import 'dart:math';
import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/tile_manager.dart';

/// Pedestrians must not freeze face-to-face, ghost through each other, OR bounce
/// nervously past one another. The behaviour: each walker ANTICIPATES (from both
/// walkers' velocities) whether it will pass another too close; if so it commits
/// to one side and drifts there calmly, then eases back once past — and it never
/// stops for another ped (only for cars / the player). A pair that will already
/// pass cleanly on their keep-right lanes does nothing at all.
///
/// These tests lock in the side-step decision (pure geometry, facing +x so
/// forward is +x and "right" is +y) and the integrated behaviour across the
/// three encounters: head-on (calm, no swerve), catch-up, and a corner crossing.
void main() {
  Pedestrian makePed(Spline path, {double speed = 20}) => Pedestrian(
        crossingPath: path,
        walkSpeed: speed,
        color: const Color(0xFF1565C0),
        skinColor: const Color(0xFFF1C9A5),
        hairColor: const Color(0xFF20140A),
      );

  /// Step [peds] for [frames] frames exactly as TileManager does: predict each
  /// ped's side-step from a snapshot of all keep-right LANE positions + intended
  /// velocities (not the leaned positions), feed it back, then advance. Reports
  /// the minimum centre-to-centre distance seen, whether every ped advanced every
  /// frame (never stalled), and the largest deviation of any ped's lateral offset
  /// from the keep-right baseline (how hard anyone swerved).
  ({double minDist, bool allAdvanced, double maxLean}) simulate(
      List<Pedestrian> peds, int frames,
      {double dt = 1 / 60}) {
    var minDist = double.infinity;
    var allAdvanced = true;
    var maxLean = 0.0;
    for (var i = 0; i < frames; i++) {
      final before = [for (final p in peds) p.distanceTravelled];
      final lanePos = <Vector2>[];
      final vel = <Vector2>[];
      for (final p in peds) {
        final a = p.splineAngle;
        final c = p.splineCentrePosition;
        lanePos.add(Vector2(
            c.x - sin(a) * kPedLaneOffset, c.y + cos(a) * kPedLaneOffset));
        vel.add(Vector2(cos(a) * p.walkSpeed, sin(a) * p.walkSpeed));
      }
      for (var j = 0; j < peds.length; j++) {
        peds[j]
            .setAvoidance(TileManager.pedAvoidSideStep(lanePos[j], vel[j], lanePos, vel));
      }
      for (final p in peds) {
        p.update(dt);
      }
      for (var j = 0; j < peds.length; j++) {
        // A ped that hasn't reached its end must keep advancing — never stop for
        // another ped.
        if (!peds[j].hasCrossed && peds[j].distanceTravelled <= before[j]) {
          allAdvanced = false;
        }
        final lean = (peds[j].lateralOffset - kPedLaneOffset).abs();
        if (lean > maxLean) maxLean = lean;
      }
      for (var a = 0; a < peds.length; a++) {
        for (var b = a + 1; b < peds.length; b++) {
          final d = peds[a].position.distanceTo(peds[b].position);
          if (d < minDist) minDist = d;
        }
      }
    }
    return (minDist: minDist, allAdvanced: allAdvanced, maxLean: maxLean);
  }

  group('pedAvoidSideStep (pure geometry; facing +x → forward +x, right +y)', () {
    final pos = Vector2.zero();
    final vel = Vector2(20, 0); // moving +x

    double step(List<Vector2> p, List<Vector2> v) =>
        TileManager.pedAvoidSideStep(pos, vel, [pos, ...p], [vel, ...v]);

    test('clear road → no side-step', () {
      expect(step(const [], const []), 0.0);
    });

    test('a ped behind is ignored', () {
      expect(step([Vector2(-12, 0)], [Vector2(20, 0)]), 0.0);
    });

    test('a ped whose closest approach is too far off in time is ignored', () {
      // Head-on but very far ahead → time-to-approach exceeds the horizon.
      expect(step([Vector2(200, 0)], [Vector2(-20, 0)]), 0.0);
    });

    test('a ped already moving away (closest approach behind) is ignored', () {
      // Ahead and pulling away faster in the same direction.
      expect(step([Vector2(40, 0)], [Vector2(40, 0)]), 0.0);
    });

    test('a clean keep-right pass (will miss by 2×offset) does NOT swerve', () {
      // Head-on, offset by the full lane separation → predicted miss = 24 > the
      // threshold, so it is recognised as a normal pass and ignored.
      expect(
          step([Vector2(40, 2 * kPedLaneOffset)], [Vector2(-20, 0)]), 0.0);
    });

    test('catching up a same-direction walker → overtake in the opposite lane',
        () {
      // Other ahead, moving my way but slower → swap to the open opposite lane.
      expect(step([Vector2(16, 0)], [Vector2(8, 0)]), -2 * kPedLaneOffset);
    });

    test('a dead-on near-oncoming collision → step right (+)', () {
      expect(step([Vector2(40, 0)], [Vector2(-20, 0)]), kPedSideStep);
    });

    test('a crosser whose closest approach is on my right → step left (−)', () {
      // Approaches from below-right but crosses upward, so it passes on my
      // right (+y) at closest approach → step left, away from it.
      expect(step([Vector2(20, -12)], [Vector2(0, 20)]), -kPedSideStep);
    });

    test('a crosser whose closest approach is on my left → step right (+)', () {
      expect(step([Vector2(20, 12)], [Vector2(0, -20)]), kPedSideStep);
    });

    test('reacts to the SOONEST converging ped', () {
      // Two near-oncoming threats; the nearer (sooner) one is on my left → right.
      final r = step(
        [Vector2(80, 6), Vector2(30, -6)],
        [Vector2(-20, 0), Vector2(-20, 0)],
      );
      expect(r, kPedSideStep);
    });
  });

  group('integrated behaviour — calm, no stop, no ghost', () {
    test('head-on walkers pass calmly without swerving (the reported case)', () {
      final a = makePed(Spline([
        Vector2(-100, 0),
        Vector2(-33, 0),
        Vector2(33, 0),
        Vector2(100, 0),
      ]));
      final b = makePed(Spline([
        Vector2(100, 0),
        Vector2(33, 0),
        Vector2(-33, 0),
        Vector2(-100, 0),
      ]));
      final r = simulate([a, b], 360);
      expect(r.allAdvanced, isTrue, reason: 'neither ever stops');
      // Keep-right alone holds them 2×offset apart, a clean pass — so they do
      // NOT swerve at all (no nervous bouncing).
      expect(r.maxLean, lessThan(0.5), reason: 'no needless side-step');
      expect(r.minDist, greaterThan(2 * kPedLaneOffset - 2),
          reason: 'a clear gap (~2×offset), shoulders do not clip');
    });

    test('a fast walker overtakes a slow one without stopping or overlapping',
        () {
      final line = [
        Vector2(0, 0),
        Vector2(133, 0),
        Vector2(266, 0),
        Vector2(400, 0),
      ];
      final leader = makePed(Spline(List.of(line)), speed: 18);
      final follower = makePed(Spline(List.of(line)), speed: 34);
      // Stagger the leader ahead, then refresh its position to that point.
      leader.setT(0.12);
      leader.update(0.0);
      final r = simulate([leader, follower], 360);
      expect(r.allAdvanced, isTrue, reason: 'the follower never halts');
      expect(r.maxLean, greaterThan(0.0), reason: 'a side-step actually fired');
      // Overtaking in the opposite lane → a real gap as they pass, not the old
      // half-body overlap.
      expect(r.minDist, greaterThan(14.0),
          reason: 'clears properly, no shoulder overlap');
    });

    test('perpendicular corner: both keep moving and steer clear', () {
      // A sidewalk stroller and a road-crosser meeting at a corner on courses
      // that converge near the same point — the conflict the base keep-right
      // offset can't resolve, so the side-step must. Different paces (as real
      // walkers have) so it isn't a degenerate mirror-image stand-off.
      final a = makePed(
          Spline([
            Vector2(-60, 0),
            Vector2(-20, 0),
            Vector2(20, 0),
            Vector2(60, 0),
          ]),
          speed: 22);
      final b = makePed(
          Spline([
            Vector2(0, -40),
            Vector2(0, -7),
            Vector2(0, 26),
            Vector2(0, 60),
          ]),
          speed: 17);
      final r = simulate([a, b], 320);
      expect(r.allAdvanced, isTrue, reason: 'neither freezes at the corner');
      expect(r.maxLean, greaterThan(0.0), reason: 'a side-step actually fired');
      expect(r.minDist, greaterThan(6.0), reason: 'they steer clear, not ghost');
    });
  });
}
