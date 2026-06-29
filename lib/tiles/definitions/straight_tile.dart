import 'dart:ui';
import 'package:flame/components.dart';
import '../../core/constants.dart';
import '../../core/spline.dart';
import '../environment.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../scenarios/scenario_base.dart';
import '../scenarios/scenario_registry.dart';
import '../scenarios/free_drive_scenario.dart';

/// A straight four-lane road tile (two lanes each direction, US style).
///
/// Layout (Y axis = up = forward):
///   Entry at bottom; exit at top.
///   Player side (positive X of centreline): inner lane (next to the centre
///   line) + outer/curb lane. Oncoming side (negative X): two mirrored lanes.
///   The inner player lane stays at _cx + kLaneWidth*0.5 so the seam still
///   lines up with the single-lane intersection's through-lane.
///
/// Coordinate system: origin = bottom-left of tile.
///   X → right
///   Y → up (forward direction of travel)
class StraightTile extends TileBase {
  StraightTile({ScenarioBase? scenario, super.locale})
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
        locale: ctx.locale,
      ),
      entryLanes: 2,
      exitLanes: 2,
    );
  }

  // ---------------------------------------------------------------------------
  // Geometry helpers
  // ---------------------------------------------------------------------------

  static const double _cx = kTileSize / 2; // horizontal centre

  // Two lanes each way. Lane centres step out by one lane width from the
  // centreline on each side.
  // Player side (positive X):
  static const double _playerInnerX = _cx + kLaneWidth * 0.5; // 640 — seam lane
  static const double _playerOuterX = _cx + kLaneWidth * 1.5; // 720 — curb lane
  // Oncoming side (negative X):
  static const double _oncomingInnerX = _cx - kLaneWidth * 0.5; // 560
  static const double _oncomingOuterX = _cx - kLaneWidth * 1.5; // 480

  // This tile's road is wider than the shared kRoadWidth (which still describes
  // the single-lane tiles). Derive it locally so intersection/start tiles are
  // untouched: 2 lanes each side → 4 lane widths total.
  static const double _roadHalfWidth = kLaneWidth * 2; // 160
  static const double _roadWidth = _roadHalfWidth * 2; // 320

  // ---------------------------------------------------------------------------
  // Splines (tile-local coords, origin = bottom-left)
  // ---------------------------------------------------------------------------

  // Built once per tile instance — spline identity is stable for the tile's
  // lifetime (TileManager's seam matching relies on it) and the arc-length
  // LUT is only computed once.

  /// Player travels bottom (high Y) → top (low Y) — upward on screen.
  /// Ordered inner → outer; [playerPaths.first] is the inner lane that lines
  /// up with the intersection seam, so it stays the default/bootstrap lane.
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
  late final List<Spline> playerPaths = [
    _northbound(_playerInnerX), // seam lane — must stay first
    _northbound(_playerOuterX), // curb lane
  ];

  @override
  late final List<Spline> npcPaths = [
    // Oncoming traffic — top → bottom on the negative-X side.
    _southbound(_oncomingOuterX),
    _southbound(_oncomingInnerX),
    // Same direction as the player — shares the player's lanes so there is
    // realistic through-traffic ahead of and behind the player.
    _northbound(_playerInnerX),
    _northbound(_playerOuterX),
  ];

  // Entry = bottom of tile; exit = top of tile (inner/seam lane).
  @override
  Vector2 get entryAnchor => Vector2(_playerInnerX, kTileSize);

  @override
  Vector2 get exitAnchor => Vector2(_playerInnerX, 0);

  // Off-road grass strips outside each pavement — dressed with locale scenery.
  static const double _roadOuterLeft = _cx - _roadHalfWidth - kPavementWidth; // 380
  static const double _roadOuterRight = _cx + _roadHalfWidth + kPavementWidth; // 820
  // Sidewalk centrelines (ambient walkers stroll these, never the road).
  static const double _walkLeftX = _cx - _roadHalfWidth - kPavementWidth * 0.5; // 410
  static const double _walkRightX = _cx + _roadHalfWidth + kPavementWidth * 0.5; // 790

  @override
  List<Rect> get decorationZones => const [
        Rect.fromLTWH(0, 0, _roadOuterLeft, kTileSize),
        Rect.fromLTWH(_roadOuterRight, 0, kTileSize - _roadOuterRight, kTileSize),
      ];

  // Urban building blocks line each sidewalk, facing the road.
  @override
  List<Frontage> get buildingFrontages => const [
        Frontage(
            a: Offset(_walkLeftX, 0),
            b: Offset(_walkLeftX, kTileSize),
            outward: Offset(-1, 0)),
        Frontage(
            a: Offset(_walkRightX, 0),
            b: Offset(_walkRightX, kTileSize),
            outward: Offset(1, 0)),
      ];

  @override
  List<Spline> get sidewalkPaths => [
        _northbound(_walkLeftX),
        _southbound(_walkLeftX),
        _northbound(_walkRightX),
        _southbound(_walkRightX),
      ];

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  @override
  void render(Canvas canvas) {
    _drawGround(canvas);
    _drawPavement(canvas);
    _drawRoad(canvas);
    _drawMarkings(canvas);
    drawDecorations(canvas); // locale scenery in the grass margins
    debugRenderSplines(canvas); // no-op in release
  }

  void _drawGround(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, kTileSize, kTileSize),
      Paint()..color = groundColor,
    );
  }

  void _drawPavement(Canvas canvas) {
    final paint = Paint()..color = const Color(0xFFBDBDBD);
    final roadLeft = _cx - _roadWidth / 2 - kPavementWidth;
    final roadRight = _cx + _roadWidth / 2 + kPavementWidth;

    canvas.drawRect(Rect.fromLTWH(roadLeft, 0, kPavementWidth, kTileSize), paint);
    canvas.drawRect(Rect.fromLTWH(roadRight - kPavementWidth, 0, kPavementWidth, kTileSize), paint);
  }

  void _drawRoad(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(_cx - _roadWidth / 2, 0, _roadWidth, kTileSize),
      Paint()..color = const Color(0xFF424242),
    );
  }

  void _drawMarkings(Canvas canvas) {
    // Solid double-yellow centreline dividing the two travel directions.
    final centerLinePaint = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3;
    canvas.drawLine(Offset(_cx - 4, 0), Offset(_cx - 4, kTileSize), centerLinePaint);
    canvas.drawLine(Offset(_cx + 4, 0), Offset(_cx + 4, kTileSize), centerLinePaint);

    // Dashed white lane dividers between the two lanes on each side.
    _dashedLine(canvas, _cx - kLaneWidth); // between oncoming lanes
    _dashedLine(canvas, _cx + kLaneWidth); // between player lanes
  }

  void _dashedLine(Canvas canvas, double x) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 3;
    const double dashLen = 40;
    const double gapLen = 40;
    double y = 0;
    while (y < kTileSize) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, (y + dashLen).clamp(0, kTileSize)),
        paint,
      );
      y += dashLen + gapLen;
    }
  }
}
