import 'dart:math' as math;
import 'package:flame/components.dart';
import '../core/constants.dart';
import 'tile_base.dart';

/// Where (and how rotated) to put the next tile.
class TilePlacement {
  const TilePlacement({required this.worldPosition, required this.orientation});

  final Vector2 worldPosition;
  final double orientation;
}

/// Pure utility: calculates where to place the next tile so that roads line up
/// even when the corridor bends.
class TileConnector {
  TileConnector._();

  /// Canonical entry direction of every tile: the player enters heading north.
  static final Vector2 _canonicalEntryDir = Vector2(0, -1);

  /// Compute the placement for [nextTile] (still in its canonical frame) so
  /// that its entry anchor lands on [prevTile]'s world exit point and its
  /// entry direction continues [prevTile]'s world exit direction.
  static TilePlacement computeNextPlacement(
    TileBase prevTile,
    TileBase nextTile,
  ) {
    final exitDir = prevTile.worldExitDirection;

    // Rotation that maps the canonical entry direction onto the required
    // world direction.
    final orientation = math.atan2(exitDir.y, exitDir.x) -
        math.atan2(_canonicalEntryDir.y, _canonicalEntryDir.x);

    // We want: position + R(orientation)·entryAnchor == prevTile.worldExit.
    final cosO = math.cos(orientation);
    final sinO = math.sin(orientation);
    final entry = nextTile.entryAnchor;
    final rotatedEntry = Vector2(
      entry.x * cosO - entry.y * sinO,
      entry.x * sinO + entry.y * cosO,
    );

    return TilePlacement(
      worldPosition: prevTile.worldExit - rotatedEntry,
      orientation: orientation,
    );
  }

  /// True if a square tile at [placement] would overlap any tile in [others].
  /// Used to reject maneuvers that would fold the corridor back onto itself.
  /// AABBs are shrunk slightly so tiles sharing an edge don't count as overlap.
  static bool overlapsAny(TilePlacement placement, Iterable<TileBase> others) {
    const inset = 2.0;
    final a = _footprint(placement.worldPosition, placement.orientation);
    for (final tile in others) {
      final b = _footprint(tile.position, tile.orientation);
      final overlaps = a.left + inset < b.right - inset &&
          b.left + inset < a.right - inset &&
          a.top + inset < b.bottom - inset &&
          b.top + inset < a.bottom - inset;
      if (overlaps) return true;
    }
    return false;
  }

  /// World-space AABB of a square tile rotated by [orientation] about its
  /// top-left origin at [pos].
  static ({double left, double top, double right, double bottom}) _footprint(
    Vector2 pos,
    double orientation,
  ) {
    final cosO = math.cos(orientation);
    final sinO = math.sin(orientation);
    double minX = pos.x, maxX = pos.x, minY = pos.y, maxY = pos.y;
    for (final corner in const [
      (kTileSize, 0.0),
      (0.0, kTileSize),
      (kTileSize, kTileSize),
    ]) {
      final x = pos.x + corner.$1 * cosO - corner.$2 * sinO;
      final y = pos.y + corner.$1 * sinO + corner.$2 * cosO;
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }
    return (left: minX, top: minY, right: maxX, bottom: maxY);
  }
}
