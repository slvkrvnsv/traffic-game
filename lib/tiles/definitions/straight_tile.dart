import 'dart:ui';
import 'package:flame/components.dart';
import '../../core/constants.dart';
import '../../core/spline.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../scenarios/scenario_base.dart';
import '../scenarios/scenario_registry.dart';
import '../scenarios/free_drive_scenario.dart';

/// A straight two-lane road tile.
///
/// Layout (Y axis = up = forward):
///   Entry at bottom-centre; exit at top-centre.
///   Two lanes: player drives in right lane (positive X side).
///   NPC traffic comes in both directions.
///
/// Coordinate system: origin = bottom-left of tile.
///   X → right
///   Y → up (forward direction of travel)
class StraightTile extends TileBase {
  StraightTile({ScenarioBase? scenario})
      : super(
          tileType: TileType.straight,
          scenario: scenario ?? FreeDriveScenario(),
        );

  // ---------------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------------
  static void register() {
    TileRegistry.register(
      TileType.straight,
      (ctx) => StraightTile(
        scenario: ScenarioRegistry.forTile(TileType.straight, rng: ctx.rng),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Geometry helpers
  // ---------------------------------------------------------------------------

  static const double _cx = kTileSize / 2; // horizontal centre
  // Right lane (player): half-lane right of centreline
  static const double _playerLaneX = _cx + kLaneWidth * 0.5;
  // Left lane (oncoming NPC): half-lane left of centreline
  static const double _oncomingLaneX = _cx - kLaneWidth * 0.5;

  // ---------------------------------------------------------------------------
  // Splines (tile-local coords, origin = bottom-left)
  // ---------------------------------------------------------------------------

  // Built once per tile instance — spline identity is stable for the tile's
  // lifetime (TileManager's seam matching relies on it) and the arc-length
  // LUT is only computed once.

  // Player travels bottom (high Y) → top (low Y) — upward on screen.
  @override
  late final List<Spline> playerPaths = [
    Spline([
      Vector2(_playerLaneX, kTileSize),
      Vector2(_playerLaneX, kTileSize * 0.66),
      Vector2(_playerLaneX, kTileSize * 0.33),
      Vector2(_playerLaneX, 0),
    ]),
  ];

  @override
  late final List<Spline> npcPaths = [
    // Lane 0 — oncoming: top → bottom (left lane).
    Spline([
      Vector2(_oncomingLaneX, 0),
      Vector2(_oncomingLaneX, kTileSize * 0.33),
      Vector2(_oncomingLaneX, kTileSize * 0.66),
      Vector2(_oncomingLaneX, kTileSize),
    ]),
    // Lane 1 — same direction as player: bottom → top (right lane).
    // Shares the player's travel lane so there is realistic through-traffic
    // ahead of and behind the player; connects to the intersection's
    // north-bound lane at the seam (x = _playerLaneX).
    Spline([
      Vector2(_playerLaneX, kTileSize),
      Vector2(_playerLaneX, kTileSize * 0.66),
      Vector2(_playerLaneX, kTileSize * 0.33),
      Vector2(_playerLaneX, 0),
    ]),
  ];

  // Entry = bottom of tile; exit = top of tile.
  @override
  Vector2 get entryAnchor => Vector2(_playerLaneX, kTileSize);

  @override
  Vector2 get exitAnchor => Vector2(_playerLaneX, 0);

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  @override
  void render(Canvas canvas) {
    _drawGround(canvas);
    _drawPavement(canvas);
    _drawRoad(canvas);
    _drawMarkings(canvas);
    debugRenderSplines(canvas); // no-op in release
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kTileSize, kTileSize),
      Paint()..color = const Color(0xFF4CAF50), // grass green
    );
  }

  void _drawPavement(Canvas canvas) {
    final paint = Paint()..color = const Color(0xFFBDBDBD);
    final roadLeft = _cx - kRoadWidth / 2 - kPavementWidth;
    final roadRight = _cx + kRoadWidth / 2 + kPavementWidth;

    canvas.drawRect(Rect.fromLTWH(roadLeft, 0, kPavementWidth, kTileSize), paint);
    canvas.drawRect(Rect.fromLTWH(roadRight - kPavementWidth, 0, kPavementWidth, kTileSize), paint);
  }

  void _drawRoad(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(_cx - kRoadWidth / 2, 0, kRoadWidth, kTileSize),
      Paint()..color = const Color(0xFF424242),
    );
  }

  void _drawMarkings(Canvas canvas) {
    final centerLinePaint = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3;

    const double dashLen = 40;
    const double gapLen = 40;
    double y = 0;
    while (y < kTileSize) {
      canvas.drawLine(
        Offset(_cx, y),
        Offset(_cx, (y + dashLen).clamp(0, kTileSize)),
        centerLinePaint,
      );
      y += dashLen + gapLen;
    }
  }
}
