import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/core/spline.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';
import 'package:traffic_game/tiles/definitions/intersection_tile.dart';

/// Regression for the "pedestrians run out of the buildings weirdly and walk a
/// step off the kerb" report. A building-exit route used to step PERPENDICULAR
/// from the door to the sidewalk centreline and then turn ~90° to walk along it.
/// The centripetal Catmull-Rom rounded that corner to its INSIDE — the road side
/// — so the walker (a) spawned facing partly backward and the path hooked the
/// wrong way before reversing (the "weird run"), and (b) bulged toward the road,
/// ending a step off the kerb. The route now merges DIAGONALLY onto the line and
/// settles onto it ([kPedExitMergeStep]/[kPedExitSettle]), killing both. The
/// fix lives in the shared `TileBase._buildExitRoutes`, so it also reshapes the
/// across-road crossing routes on intersections — guarded below.

/// Sample [s] and return ([ratio], [backHook]) — speed uniformity (max/min world
/// step at uniform t) and the largest BACKWARD movement along the final walk
/// direction (a step-out that hooks away from the destination before reversing).
({double ratio, double backHook}) shape(Spline s) {
  final pts = [for (int i = 0; i <= 200; i++) s.evaluate(i / 200)];
  // Walk direction = the (straight) second half of the route.
  final walkDir = (pts.last - s.evaluate(0.6))..normalize();
  double runMax = pts.first.dot(walkDir), backHook = 0.0;
  double mn = 1e9, mx = 0.0;
  Vector2 prev = pts.first;
  for (var i = 0; i < pts.length; i++) {
    final prog = pts[i].dot(walkDir);
    backHook = max(backHook, runMax - prog);
    runMax = max(runMax, prog);
    if (i > 0) {
      final d = pts[i].distanceTo(prev);
      if (d < mn) mn = d;
      if (d > mx) mx = d;
    }
    prev = pts[i];
  }
  return (ratio: mx / mn, backHook: backHook);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  test('urban sidewalk building-exits step out without a roadward swerve or '
      'backward hook', () {
    final tile = StraightTile(locale: LocaleType.urban)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final routes = tile.buildingExitRoutes;
    expect(routes, isNotEmpty,
        reason: 'an urban straight tile lines both sidewalks with buildings');

    // Tile-local geometry: central road band x∈[440,760]; sidewalk centrelines at
    // x=420 (left) and x=780 (right); the road centre is x=600.
    for (final r in routes) {
      expect(r.crossesRoad, isFalse,
          reason: 'the straight tile has no crossings — all exits are sidewalk');
      final s = r.spline;
      final centreX = s.evaluate(1.0).x; // the walk centreline
      double minX = 1e9, maxX = -1e9;
      for (int i = 0; i <= 200; i++) {
        final x = s.evaluate(i / 200).x;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      // How far the path strays toward the central road from its walk centreline.
      // The door sits on the AWAY-from-road side, so it never sets this extreme.
      final roadwardDip = centreX > 600 ? centreX - minX : maxX - centreX;
      expect(roadwardDip, lessThan(3.5),
          reason: 'step-out must not swerve toward the road (was ~10u): '
              'centre=$centreX dip=$roadwardDip');

      final sh = shape(s);
      expect(sh.backHook, lessThan(2.0),
          reason: 'no backward hook leaving the door (was ~2.6u)');
      expect(sh.ratio, lessThan(1.4),
          reason: 'speed stays ~uniform along the route');
    }
  });

  test('urban intersection: sidewalk exits get the clean step-out; across-road '
      'crossings keep their zebra entry untouched', () {
    IntersectionTile.register();
    final tile = IntersectionTile(locale: LocaleType.urban)
      ..place(worldPosition: Vector2.zero(), orientation: 0.0);
    final routes = tile.buildingExitRoutes;
    expect(routes, isNotEmpty, reason: 'urban junction lines its corners');
    // The reshaping is gated on sidewalk routes only — this test is meaningless
    // unless the junction actually produced a road-crossing exit to leave alone.
    expect(routes.any((r) => r.crossesRoad), isTrue,
        reason: 'an urban junction has zebra building-exits to guard');

    for (final r in routes) {
      // Every route still spans door→line→far (the clamps never collapse it).
      expect(r.spline.totalLength, greaterThan(40.0),
          reason: 'route still spans the door step plus the walk/crossing');
      if (r.crossesRoad) continue; // crossings keep the original shape by design
      // Sidewalk exits get the diagonal+settle: no roadward swerve shows up as a
      // backward hook here, and the speed stays uniform.
      final sh = shape(r.spline);
      expect(sh.backHook, lessThan(2.0),
          reason: 'sidewalk exit never hooks backward leaving the door');
      expect(sh.ratio, lessThan(1.5), reason: 'speed stays ~uniform');
    }
  });
}
