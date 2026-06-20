import 'package:flame/components.dart';
import 'package:flutter/painting.dart';
import '../../core/constants.dart';
import '../../core/spline.dart';
import '../../cars/npc_car.dart';
import '../../cars/player_car.dart';
import '../../pedestrians/pedestrian.dart';
import '../tile_base.dart';
import '../tile_registry.dart';
import '../scenarios/free_drive_scenario.dart';

/// The opening tile: a quiet dead-end stub.
///
/// The player starts parked at the closed end and simply drives straight
/// forward up the lane — traffic begins on the tiles that follow. The road and
/// lane geometry match [StraightTile], so the exit seam connects to whatever
/// comes next. Never spawned at random — [TileManager] only ever places it as
/// the very first tile — so it carries no exam scenario beyond "don't crash".
///
/// Canonical frame: origin top-left, x → right, y → down, forward = -y.
class StartTile extends TileBase {
  StartTile({super.locale})
      : super(
          tileType: TileType.start,
          scenario: FreeDriveScenario(),
        );

  /// Registered (not spawnable) so its lane profile is known: the free-drive
  /// chainer looks up the previous tile's exit lane count, and the very first
  /// spawned tile follows [StartTile]. Exits the single seam lane (x=640).
  static void register() {
    TileRegistry.register(
      TileType.start,
      (ctx) => StartTile(locale: ctx.locale),
      entryLanes: 1,
      exitLanes: 1,
      spawnable: false,
    );
  }

  static const double _cx = kTileSize / 2; // road centreline
  static const double _laneX = _cx + kLaneWidth * 0.5; // 640 — right lane
  static const double _deadEndY = 1150.0; // the road closes here
  static const double _startY = 1080.0; // parked just inside the dead end

  // Straight up the right lane, away from the dead end.
  @override
  late final List<Spline> playerPaths = [
    Spline([
      Vector2(_laneX, _startY),
      Vector2(_laneX, _startY * 0.66),
      Vector2(_laneX, _startY * 0.33),
      Vector2(_laneX, 0),
    ]),
  ];

  // No traffic on the dead end — the player is the only car leaving it.
  @override
  List<Spline> get npcPaths => const [];

  @override
  Vector2 get entryAnchor => Vector2(_laneX, _startY);

  @override
  Vector2 get exitAnchor => Vector2(_laneX, 0);

  // ---------------------------------------------------------------------------
  // Rules — a standstill is legitimate while still parked at the dead end, so
  // the road-blocking penalty is exempt until the player rolls forward.
  // ---------------------------------------------------------------------------
  bool _rolledOut = false;

  @override
  void updateNpcSensors(double dt, PlayerCar playerCar, List<NpcCar> allNpcs,
      List<Pedestrian> pedestrians) {
    super.updateNpcSensors(dt, playerCar, allNpcs, pedestrians);
    if (!_rolledOut && worldToLocal(playerCar.position).y < _startY - 30) {
      _rolledOut = true; // pulled away — normal rules from here
    }
  }

  @override
  bool get playerMustWait => !_rolledOut;

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
      Paint()..color = groundColor,
    );
  }

  /// Sidewalk runs down both sides and wraps across the closed end.
  void _drawPavement(Canvas canvas) {
    final p = Paint()..color = const Color(0xFFBDBDBD);
    final left = _cx - kRoadWidth / 2 - kPavementWidth; // 480
    final right = _cx + kRoadWidth / 2; // 680 — right kerb
    final capBottom = _deadEndY + kPavementWidth; // 1190
    canvas.drawRect(Rect.fromLTWH(left, 0, kPavementWidth, capBottom), p);
    canvas.drawRect(Rect.fromLTWH(right, 0, kPavementWidth, capBottom), p);
    canvas.drawRect(
      Rect.fromLTWH(left, _deadEndY, right + kPavementWidth - left, kPavementWidth),
      p,
    );
  }

  void _drawRoad(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(_cx - kRoadWidth / 2, 0, kRoadWidth, _deadEndY),
      Paint()..color = const Color(0xFF424242),
    );
  }

  void _drawMarkings(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFFFFD600)
      ..strokeWidth = 3;
    const dashLen = 40.0;
    const gapLen = 40.0;
    double y = 0;
    while (y < _deadEndY) {
      canvas.drawLine(
        Offset(_cx, y),
        Offset(_cx, (y + dashLen).clamp(0, _deadEndY)),
        paint,
      );
      y += dashLen + gapLen;
    }
  }
}
