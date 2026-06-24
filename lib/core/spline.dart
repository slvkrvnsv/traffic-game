import 'dart:math' as math;
import 'package:flame/components.dart';

/// Immutable Catmull-Rom spline that passes through every control point.
///
/// Parameterized by arc-length (t ∈ [0, 1]) so that advancing by a fixed
/// distance gives visually uniform movement regardless of point density.
class Spline {
  Spline(List<Vector2> points)
      : assert(points.length >= 2, 'Spline needs at least 2 points'),
        _points = List.unmodifiable(points) {
    _buildLut();
  }

  final List<Vector2> _points;

  // Arc-length LUT: _lut[i] = cumulative arc-length at raw parameter i/kSamples
  static const int _kSamples = 200;
  late final List<double> _lut; // length = _kSamples + 1
  late final double _totalLength;

  double get totalLength => _totalLength;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Position on the spline at normalised arc-length parameter [t] ∈ [0, 1].
  Vector2 evaluate(double t) {
    t = t.clamp(0.0, 1.0);
    final rawT = _arcLengthToRaw(t * _totalLength);
    return _catmullRom(rawT);
  }

  /// Unit tangent (direction of travel) at normalised arc-length parameter [t].
  ///
  /// Computed as a finite difference in arc-length space, which stays
  /// well-defined right at the endpoints (a forward/backward step there) —
  /// unlike a raw-parameter derivative, which collapses where the spline's
  /// end control points are duplicated.
  Vector2 tangent(double t) {
    t = t.clamp(0.0, 1.0);
    const dt = 1e-3;
    final lo = (t - dt).clamp(0.0, 1.0);
    final hi = (t + dt).clamp(0.0, 1.0);
    final dir = evaluate(hi) - evaluate(lo);
    if (dir.length2 < 1e-12) return Vector2(1, 0); // degenerate: arbitrary
    return dir.normalized();
  }

  /// Angle in radians of the tangent at [t]. 0 = right, π/2 = down (screen).
  double angleAt(double t) {
    final tgt = tangent(t);
    return math.atan2(tgt.y, tgt.x);
  }

  /// Convert a travelled distance [d] (in world units) to normalised [t].
  double distanceToT(double d) {
    return (d / _totalLength).clamp(0.0, 1.0);
  }

  /// Arc-length distance (world units) of the point on the spline NEAREST [p].
  /// For a point that lies ON the spline — e.g. where a turn branch taps onto a
  /// through-lane spine — this is where along the lane it attaches, so a fork can
  /// fire at exactly that distance. Coarse scan (64) then a short ternary refine,
  /// so it's precise enough to place a tap without quantisation slop.
  double distanceAtNearest(Vector2 p) {
    double bt = 0.0, bd = double.infinity;
    const n = 64;
    for (int i = 0; i <= n; i++) {
      final t = i / n;
      final d2 = (evaluate(t) - p).length2;
      if (d2 < bd) {
        bd = d2;
        bt = t;
      }
    }
    double lo = (bt - 1.0 / n).clamp(0.0, 1.0);
    double hi = (bt + 1.0 / n).clamp(0.0, 1.0);
    for (int k = 0; k < 16; k++) {
      final m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
      if ((evaluate(m1) - p).length2 < (evaluate(m2) - p).length2) {
        hi = m2;
      } else {
        lo = m1;
      }
    }
    return ((lo + hi) / 2) * _totalLength;
  }

  // ---------------------------------------------------------------------------
  // Arc-length LUT construction
  // ---------------------------------------------------------------------------

  void _buildLut() {
    _lut = List.filled(_kSamples + 1, 0.0);
    _lut[0] = 0.0;

    Vector2 prev = _catmullRom(0.0);
    for (int i = 1; i <= _kSamples; i++) {
      final rawT = i / _kSamples;
      final curr = _catmullRom(rawT);
      _lut[i] = _lut[i - 1] + prev.distanceTo(curr);
      prev = curr;
    }
    _totalLength = _lut[_kSamples];
  }

  /// Binary-search the LUT to convert arc-length [s] to raw parameter.
  double _arcLengthToRaw(double s) {
    s = s.clamp(0.0, _totalLength);
    int lo = 0, hi = _kSamples;
    while (lo < hi - 1) {
      final mid = (lo + hi) ~/ 2;
      if (_lut[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    // Linear interpolation between lo and hi
    final segLen = _lut[hi] - _lut[lo];
    if (segLen < 1e-9) return lo / _kSamples;
    final frac = (s - _lut[lo]) / segLen;
    return (lo + frac) / _kSamples;
  }

  // ---------------------------------------------------------------------------
  // Catmull-Rom evaluation (raw parameter rawT ∈ [0, 1] mapped over all segments)
  // ---------------------------------------------------------------------------

  /// Number of segments = points.length - 1
  int get _segments => _points.length - 1;

  /// Evaluate the Catmull-Rom spline at raw parameter [rawT] ∈ [0, 1].
  Vector2 _catmullRom(double rawT) {
    rawT = rawT.clamp(0.0, 1.0);

    if (rawT >= 1.0) return _points.last.clone();

    final scaledT = rawT * _segments;
    final seg = scaledT.floor().clamp(0, _segments - 1);
    final localT = scaledT - seg;

    final p0 = _points[(seg - 1).clamp(0, _points.length - 1)];
    final p1 = _points[seg];
    final p2 = _points[(seg + 1).clamp(0, _points.length - 1)];
    final p3 = _points[(seg + 2).clamp(0, _points.length - 1)];

    return _catmullRomPoint(p0, p1, p2, p3, localT);
  }

  /// Centripetal Catmull-Rom (alpha = 0.5) via the Barry-Goldman pyramid.
  ///
  /// Centripetal parameterisation spaces the internal knots by the square root
  /// of the chord length, which provably removes the overshoot and cusps that
  /// uniform Catmull-Rom produces when control points are unevenly spaced — so
  /// a turn curves cleanly instead of bulging the wrong way before it bends.
  static Vector2 _catmullRomPoint(
      Vector2 p0, Vector2 p1, Vector2 p2, Vector2 p3, double t) {
    // Knot deltas = chord^0.5. Each is floored to a tiny epsilon so duplicated
    // endpoint controls (used to clamp the spline ends) can't divide by zero —
    // for equal points the affected term collapses to that point safely.
    double delta(Vector2 a, Vector2 b) {
      final d = math.sqrt(a.distanceTo(b));
      return d < 1e-5 ? 1e-5 : d;
    }

    const t0 = 0.0;
    final t1 = t0 + delta(p0, p1);
    final t2 = t1 + delta(p1, p2);
    final t3 = t2 + delta(p2, p3);

    // Map local t ∈ [0,1] onto the active [t1, t2] knot interval.
    final tt = t1 + (t2 - t1) * t;

    final a1 = _lerpV(p0, p1, (tt - t0) / (t1 - t0));
    final a2 = _lerpV(p1, p2, (tt - t1) / (t2 - t1));
    final a3 = _lerpV(p2, p3, (tt - t2) / (t3 - t2));
    final b1 = _lerpV(a1, a2, (tt - t0) / (t2 - t0));
    final b2 = _lerpV(a2, a3, (tt - t1) / (t3 - t1));
    return _lerpV(b1, b2, (tt - t1) / (t2 - t1));
  }

  static Vector2 _lerpV(Vector2 a, Vector2 b, double s) =>
      Vector2(a.x + (b.x - a.x) * s, a.y + (b.y - a.y) * s);
}
