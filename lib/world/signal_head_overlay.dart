import 'dart:ui';

import 'package:flame/components.dart';

import '../core/constants.dart';
import '../tiles/tile_manager.dart';

/// Paints intersection signal heads ABOVE the vehicle layer.
///
/// Tiles render at the bottom of the world (priority 0) — under pedestrians (2)
/// and cars (5/10). A signal head hung over a lane therefore has to be drawn by
/// a component that sits above the cars, or the car stopped at the light would
/// cover the head it's waiting on. This is that component: each frame it walks
/// the active tiles and, for each, replays the tile's transform (top-left
/// position + orientation) so the tile draws its heads in its own local space —
/// the exact space it draws the rest of its road in. Tiles with no signals
/// (the default [TileBase.renderSignalHeadsOverlay] is a no-op) cost one empty
/// call.
///
/// Walks [TileManager.liveTiles] (active + trailing), not just the active ones,
/// so a junction you've just driven through keeps its heads until it's culled
/// off-screen — the same lifetime as the tile's own road rendering.
class SignalHeadOverlay extends Component {
  SignalHeadOverlay({required this.tileManager})
      : super(priority: kSignalOverlayPriority);

  final TileManager tileManager;

  @override
  void render(Canvas canvas) {
    for (final tile in tileManager.liveTiles) {
      canvas.save();
      canvas.translate(tile.position.x, tile.position.y);
      canvas.rotate(tile.angle); // tiles rotate about their top-left anchor
      tile.renderSignalHeadsOverlay(canvas);
      canvas.restore();
    }
  }
}
