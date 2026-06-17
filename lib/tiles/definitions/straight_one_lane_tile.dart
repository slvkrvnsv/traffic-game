import 'dart:ui';
import 'package:flame/components.dart';
import '../../core/constants.dart';
import '../../core/spline.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../scenarios/scenario_base.dart';
import '../scenarios/scenario_registry.dart';
import '../scenarios/free_drive_scenario.dart';

/// A straight road with a single lane each direction — the same lane geometry
/// the intersection uses (player northbound at x=640, oncoming southbound at
/// x=560), so its seam lines up with both the intersection and the 2-lane
/// straight's inner lane. This is the road that sits between lane transitions.
///
/// Coordinate system: origin = bottom-left of tile. X → right, Y → up (forward).
class StraightOneLaneTile extends TileBase {
  StraightOneLaneTile({ScenarioBase? scenario})
      : super(
          tileType: TileType.straight1Lane,
          scenario: scenario ?? FreeDriveScenario(),
        );

  static void register() {
    TileRegistry.register(
      TileType.straight1Lane,
      (ctx) => StraightOneLaneTile(
        scenario:
            ScenarioRegistry.forTile(TileType.straight1Lane, rng: ctx.rng),
      ),
      // Now free-drive spawnable: the lane-match chainer only places it after a
      // 1-lane exit, so it never seams a 1-lane end onto a 2-lane start.
      entryLanes: 1,
      exitLanes: 1,
    );
  }

  static const double _cx = kTileSize / 2; // 600 — road centreline
  static const double _playerX = _cx + kLaneWidth * 0.5; // 640 — seam lane
  static const double _oncomingX = _cx - kLaneWidth * 0.5; // 560

  static Spline _northbound(double x) => Spline([
        Vector2(x, kTileSize),
        Vector2(x, kTileSize * 0.66),
        Vector2(x, kTileSize * 0.33),
        Vector2(x, 0),
      ]);

  static Spline _southbound(double x) => Spline([
        Vector2(x, 0),
        Vector2(x, kTileSize * 0.33),
        Vector2(x, kTileSize * 0.66),
        Vector2(x, kTileSize),
      ]);

  @override
  late final List<Spline> playerPaths = [_northbound(_playerX)];

  @override
  late final List<Spline> npcPaths = [
    _southbound(_oncomingX), // oncoming
    _northbound(_playerX), // same-direction through-traffic
  ];

  @override
  Vector2 get entryAnchor => Vector2(_playerX, kTileSize);

  @override
  Vector2 get exitAnchor => Vector2(_playerX, 0);

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  @override
  void render(Canvas canvas) {
    _drawGround(canvas);
    _drawPavement(canvas);
    _drawRoad(canvas);
    _drawMarkings(canvas);
    debugRenderSplines(canvas);
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kTileSize, kTileSize),
      Paint()..color = const Color(0xFF4CAF50),
    );
  }

  void _drawPavement(Canvas canvas) {
    final paint = Paint()..color = const Color(0xFFBDBDBD);
    final roadLeft = _cx - kRoadWidth / 2 - kPavementWidth;
    final roadRight = _cx + kRoadWidth / 2 + kPavementWidth;
    canvas.drawRect(
        Rect.fromLTWH(roadLeft, 0, kPavementWidth, kTileSize), paint);
    canvas.drawRect(
        Rect.fromLTWH(roadRight - kPavementWidth, 0, kPavementWidth, kTileSize),
        paint);
  }

  void _drawRoad(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(_cx - kRoadWidth / 2, 0, kRoadWidth, kTileSize),
      Paint()..color = const Color(0xFF424242),
    );
  }

  void _drawMarkings(Canvas canvas) {
    // Solid double-yellow centreline — one lane each way, no dashed divider.
    final centerLinePaint = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3;
    canvas.drawLine(
        Offset(_cx - 4, 0), Offset(_cx - 4, kTileSize), centerLinePaint);
    canvas.drawLine(
        Offset(_cx + 4, 0), Offset(_cx + 4, kTileSize), centerLinePaint);
  }
}
