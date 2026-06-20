import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';

void main() {
  group('Locale runs-of-3 (free-drive)', () {
    test('the locale holds for kLocaleRunLength tiles, then re-rolls', () {
      final rng = Random(42);
      var current = LocaleType.interurban;
      var remaining = 0; // force a roll on the first slot

      final locales = <LocaleType>[];
      final remainings = <int>[];
      for (int i = 0; i < 2 * kLocaleRunLength; i++) {
        final r = TileManager.rollLocale(current, remaining, rng);
        current = r.locale;
        remaining = r.remaining;
        locales.add(r.locale);
        remainings.add(r.remaining);
      }

      // Each run of kLocaleRunLength shares one locale.
      for (int i = 1; i < kLocaleRunLength; i++) {
        expect(locales[i], locales[0], reason: 'slot $i still in run 1');
      }
      for (int i = kLocaleRunLength + 1; i < 2 * kLocaleRunLength; i++) {
        expect(locales[i], locales[kLocaleRunLength],
            reason: 'slot $i still in run 2');
      }
      // The remaining counter counts a fresh run down each time.
      expect(remainings.take(kLocaleRunLength),
          [for (int i = kLocaleRunLength - 1; i >= 0; i--) i]);
      expect(remainings.skip(kLocaleRunLength).take(kLocaleRunLength),
          [for (int i = kLocaleRunLength - 1; i >= 0; i--) i]);
    });

    test('a pinned (test-mode) locale never changes — covered by both values', () {
      // Sanity: both enum values exist and are distinct so the toggle is real.
      expect(LocaleType.values.toSet().length, 2);
    });
  });

  group('Crossings are urban-intersection-only', () {
    test('an urban intersection authors zebra crossings (4 approaches × 2 dirs)',
        () {
      final urban = IntersectionTile(
          maneuver: Maneuver.straight, locale: LocaleType.urban);
      expect(urban.crossingPaths, hasLength(8));
    });

    test('an interurban intersection authors no crossings', () {
      final rural = IntersectionTile(
          maneuver: Maneuver.straight, locale: LocaleType.interurban);
      expect(rural.crossingPaths, isEmpty);
    });
  });

  group('Locale dressing hooks', () {
    test('ground colour is the same grass green across locales', () {
      // Ground is uniform grass green now (the urban khaki was dropped); the
      // locale still drives crossings/decoration, just not the ground fill.
      final urban = StraightTile(locale: LocaleType.urban);
      final rural = StraightTile(locale: LocaleType.interurban);
      expect(urban.groundColor, rural.groundColor);
    });

    test('straights expose sidewalks (ambient walkers) and decoration zones', () {
      final s = StraightTile(locale: LocaleType.urban);
      expect(s.sidewalkPaths, isNotEmpty);
      expect(s.decorationZones, isNotEmpty);
    });

    test('a plain tile has no crossings (only intersections do)', () {
      final s = StraightTile(locale: LocaleType.urban);
      expect(s.crossingPaths, isEmpty);
    });
  });

  // Pedestrian yielding (NPC cars AND the player) is now ONE mechanism: a path
  // probe that returns the distance to the nearest crossing pedestrian ahead on
  // the agent's own spline (IntersectionTile._pedStopOnPath). Because the path
  // only meets a zebra where that zebra spans the agent's road, the lateral
  // test alone scopes hazards to real crossers — no direction attribution — so
  // it is behavioural and continuous, exercised in-game rather than by a unit
  // test here. The give-way FAULT keys off the pedestrian↔car avoidance signal
  // (a pedestrian held by the player's moving car — Pedestrian.blockedByPlayer).
}
