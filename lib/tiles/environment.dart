import 'dart:math';
import 'dart:ui';
import '../core/constants.dart';
import 'tile_registry.dart';

/// A stretch of street that buildings line, like a city block. [a]→[b] runs
/// ALONG the sidewalk (the row of buildings is laid out down this axis) and
/// [outward] is the unit normal pointing AWAY from the road, so the block sits
/// on the grass behind the pavement with its front facing the sidewalk.
class Frontage {
  const Frontage({required this.a, required this.b, required this.outward});
  final Offset a;
  final Offset b;
  final Offset outward;
}

/// Procedural off-road dressing for a tile, chosen by [LocaleType].
///
/// The whole art style is canvas-drawn, so "prefabs" here are a small library of
/// procedural drawers. [LocaleType.urban] lines the streets with **blocks** of
/// top-down building roofs along the tile's [Frontage]s (a tidy row facing the
/// sidewalk, not a random stack); [LocaleType.interurban] scatters trees through
/// the grass [zones].
///
/// Placement is computed **once** at construction from a fixed [seed] (derived
/// from the tile's world position) and cached. Tiles recycle continuously in
/// free-drive, so generating positions in `render()` with a fresh [Random] would
/// make the scenery jitter every frame — this is deterministic and stable.
class EnvironmentDecorator {
  EnvironmentDecorator({
    required this.locale,
    required int seed,
    this.zones = const [],
    this.frontages = const [],
  }) {
    _build(Random(seed));
  }

  final LocaleType locale;
  final List<Rect> zones;
  final List<Frontage> frontages;
  final List<_Decor> _items = [];

  /// Tile-local footprints of placed buildings (urban only) — used to spawn
  /// pedestrians leaving them. Empty for interurban (trees).
  List<Rect> get buildingFootprints => [
        for (final d in _items)
          if (!d.isTree)
            Rect.fromCenter(center: Offset(d.x, d.y), width: d.w, height: d.h),
      ];

  /// Average ground area (sq units) per tree (interurban scatter). Smaller → denser.
  static const double _treeAreaPer = 90000.0;
  /// Building inner-face setback from the sidewalk centreline: clears the
  /// pavement (half its width) plus a small gap, so the block sits on the grass.
  static const double _setback = kPavementWidth / 2 + 6;

  void _build(Random rng) {
    if (locale == LocaleType.urban) {
      _buildBlocks(rng);
    } else {
      _scatterTrees(rng);
    }
    // Draw far objects first so nearer ones overlap them naturally.
    _items.sort((a, b) => a.y.compareTo(b.y));
  }

  /// Lay a row of building roofs along each frontage: side by side down the
  /// sidewalk axis, set back on the grass, front facing the sidewalk.
  void _buildBlocks(Random rng) {
    for (final f in frontages) {
      final ax = f.b.dx - f.a.dx, ay = f.b.dy - f.a.dy;
      final len = sqrt(ax * ax + ay * ay);
      if (len < 64) continue;
      final ux = ax / len, uy = ay / len; // unit along the sidewalk
      final vertical = uy.abs() > ux.abs();
      double t = 10;
      while (t < len - 10) {
        final w = 52 + rng.nextDouble() * 60; // extent along the row
        if (t + w > len - 6) break;
        final depth = 54 + rng.nextDouble() * 52; // extent away from the road
        final off = _setback + depth / 2;
        final cx = f.a.dx + ux * (t + w / 2) + f.outward.dx * off;
        final cy = f.a.dy + uy * (t + w / 2) + f.outward.dy * off;
        _items.add(_Decor.building(
          w: vertical ? depth : w,
          h: vertical ? w : depth,
          color: _buildingTones[rng.nextInt(_buildingTones.length)],
        )
          ..x = cx
          ..y = cy);
        t += w + 8 + rng.nextDouble() * 12; // gap between neighbours
      }
    }
  }

  void _scatterTrees(Random rng) {
    for (final zone in zones) {
      if (zone.width < 64 || zone.height < 64) continue;
      final count = (zone.width * zone.height / _treeAreaPer).round();
      for (int i = 0; i < count; i++) {
        final item = _tree(rng);
        // Keep the whole canopy inside the zone (place by centre within the
        // inset rect) so nothing overhangs the road or pavement.
        final h = item.halfExtent;
        final minX = zone.left + h, maxX = zone.right - h;
        final minY = zone.top + h, maxY = zone.bottom - h;
        if (maxX <= minX || maxY <= minY) continue; // canopy larger than the zone
        item.x = minX + rng.nextDouble() * (maxX - minX);
        item.y = minY + rng.nextDouble() * (maxY - minY);
        _items.add(item);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Item factories (size only; the centre is assigned during placement)
  // ---------------------------------------------------------------------------

  static const _treeGreens = [
    Color(0xFF2E7D32),
    Color(0xFF388E3C),
    Color(0xFF1B5E20),
  ];
  static const _buildingTones = [
    Color(0xFF9E9E9E),
    Color(0xFF8D9CAA),
    Color(0xFFB0A99F),
    Color(0xFF7E8A93),
  ];

  _Decor _tree(Random rng) => _Decor.tree(
        radius: 16 + rng.nextDouble() * 14,
        color: _treeGreens[rng.nextInt(_treeGreens.length)],
      );

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  void render(Canvas canvas) {
    for (final d in _items) {
      d.isTree ? _drawTree(canvas, d) : _drawBuilding(canvas, d);
    }
  }

  void _drawTree(Canvas canvas, _Decor d) {
    // Trunk.
    final trunkW = d.radius * 0.28;
    canvas.drawRect(
      Rect.fromLTWH(d.x - trunkW / 2, d.y - d.radius * 0.2, trunkW, d.radius),
      Paint()..color = const Color(0xFF5D4037),
    );
    // Soft drop shadow then canopy (two offset blobs read as foliage).
    canvas.drawCircle(Offset(d.x + 3, d.y + 3), d.radius,
        Paint()..color = const Color(0x33000000));
    canvas.drawCircle(Offset(d.x, d.y), d.radius, Paint()..color = d.color);
    canvas.drawCircle(
      Offset(d.x - d.radius * 0.3, d.y - d.radius * 0.28),
      d.radius * 0.6,
      Paint()..color = d.color.withValues(alpha: 0.85),
    );
  }

  /// A building seen straight down: a flat roof. From directly above you see the
  /// roof surface — a parapet border, the inner roof deck, and a rooftop unit or
  /// two — not a façade with windows.
  void _drawBuilding(Canvas canvas, _Decor d) {
    final rect =
        Rect.fromCenter(center: Offset(d.x, d.y), width: d.w, height: d.h);
    // Slight drop shadow for depth against the ground.
    canvas.drawRect(
      rect.shift(const Offset(3, 4)),
      Paint()..color = const Color(0x2E000000),
    );
    // Parapet (outer roof edge) = the wall colour; inner roof deck is darker.
    final deck = Color.lerp(d.color, const Color(0xFF000000), 0.28)!;
    canvas.drawRect(rect, Paint()..color = d.color);
    final inner = rect.deflate(3.5);
    canvas.drawRect(inner, Paint()..color = deck);
    // A subtle highlight along the top/left parapet edge for a lit-from-above
    // read.
    final hi = Color.lerp(d.color, const Color(0xFFFFFFFF), 0.18)!;
    canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top, rect.width, 3), Paint()..color = hi);
    canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top, 3, rect.height), Paint()..color = hi);
    // Rooftop fixtures (deterministic from the footprint, no per-frame random):
    // an A/C unit toward one corner and a small skylight toward another.
    final unit = Paint()..color = const Color(0xFF6F6F6F);
    final uw = (d.w * 0.26).clamp(8.0, 30.0);
    final uh = (d.h * 0.22).clamp(8.0, 28.0);
    canvas.drawRect(
        Rect.fromLTWH(inner.left + inner.width * 0.12,
            inner.top + inner.height * 0.14, uw, uh),
        unit);
    final sky = Paint()..color = const Color(0x88B3E5FC);
    final sw = (d.w * 0.18).clamp(6.0, 20.0);
    canvas.drawRect(
        Rect.fromLTWH(inner.right - inner.width * 0.12 - sw,
            inner.bottom - inner.height * 0.14 - sw, sw, sw),
        sky);
    // Roof outline.
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0x55000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }
}

/// One placed decoration — a tree (canopy radius) or a building (w×h block).
/// [x]/[y] (centre) are assigned during placement once the size is known.
class _Decor {
  _Decor.tree({required this.radius, required this.color})
      : isTree = true,
        w = 0,
        h = 0;
  _Decor.building({required this.w, required this.h, required this.color})
      : isTree = false,
        radius = 0;

  final bool isTree;
  double x = 0;
  double y = 0;
  final double radius;
  final double w;
  final double h;
  final Color color;

  /// Half the item's footprint (incl. a little slack for shadow/second blob),
  /// used to keep the whole thing inside its zone.
  double get halfExtent => isTree ? radius * 1.15 : max(w, h) / 2 + 6;
}
