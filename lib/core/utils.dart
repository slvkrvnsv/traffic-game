import 'dart:math' as math;
import 'package:flame/components.dart';

/// Linear interpolation.
double lerp(double a, double b, double t) => a + (b - a) * t.clamp(0.0, 1.0);

/// Normalise an angle to [-π, π].
double normaliseAngle(double angle) {
  while (angle > math.pi) { angle -= 2 * math.pi; }
  while (angle < -math.pi) { angle += 2 * math.pi; }
  return angle;
}

/// Shortest-path angle lerp.
double lerpAngle(double a, double b, double t) {
  final diff = normaliseAngle(b - a);
  return a + diff * t.clamp(0.0, 1.0);
}

/// Returns [true] if the two axis-aligned rectangles overlap by more than
/// [fraction] of the smaller rect's area.
bool aabbOverlap(
  Vector2 posA, double wA, double hA,
  Vector2 posB, double wB, double hB, {
  double fraction = 0.0,
}) {
  final ax1 = posA.x - wA / 2;
  final ax2 = posA.x + wA / 2;
  final ay1 = posA.y - hA / 2;
  final ay2 = posA.y + hA / 2;

  final bx1 = posB.x - wB / 2;
  final bx2 = posB.x + wB / 2;
  final by1 = posB.y - hB / 2;
  final by2 = posB.y + hB / 2;

  final ox = math.max(0.0, math.min(ax2, bx2) - math.max(ax1, bx1));
  final oy = math.max(0.0, math.min(ay2, by2) - math.max(ay1, by1));
  final overlapArea = ox * oy;

  if (fraction <= 0) return overlapArea > 0;

  final smallerArea = math.min(wA * hA, wB * hB);
  return overlapArea >= smallerArea * fraction;
}

/// Separating Axis Theorem test for two oriented rectangles.
/// [wA]/[hA] are full width/height; [angleA] is the forward angle (atan2 convention).
/// Returns true on any contact — no overlap fraction, fires on slightest touch.
bool obbOverlap(
  Vector2 posA, double wA, double hA, double angleA,
  Vector2 posB, double wB, double hB, double angleB,
) {
  // Half-extents
  final hwA = wA / 2, hhA = hA / 2;
  final hwB = wB / 2, hhB = hB / 2;

  // Local axes: forward = length direction, side = width direction
  final cosA = math.cos(angleA), sinA = math.sin(angleA);
  final cosB = math.cos(angleB), sinB = math.sin(angleB);

  final fwdA = Vector2(cosA, sinA);
  final sideA = Vector2(-sinA, cosA);
  final fwdB = Vector2(cosB, sinB);
  final sideB = Vector2(-sinB, cosB);

  final d = posB - posA;

  for (final axis in [fwdA, sideA, fwdB, sideB]) {
    final rA = fwdA.dot(axis).abs() * hhA + sideA.dot(axis).abs() * hwA;
    final rB = fwdB.dot(axis).abs() * hhB + sideB.dot(axis).abs() * hwB;
    if (d.dot(axis).abs() > rA + rB) return false;
  }
  return true;
}

/// Shortest distance from point [p] to the oriented box centred at [boxCenter]
/// ([w] = full width across, [l] = full length along [angle]). Returns 0 when
/// the point is inside the box. Used for circular proximity (e.g. a pedestrian's
/// personal-space bubble against a car body).
double pointToObbDistance(
    Vector2 p, Vector2 boxCenter, double w, double l, double angle) {
  final d = p - boxCenter;
  final cosA = math.cos(angle), sinA = math.sin(angle);
  final along = d.x * cosA + d.y * sinA; // along the length axis
  final across = -d.x * sinA + d.y * cosA; // along the width axis
  final ox = math.max(across.abs() - w / 2, 0.0);
  final oy = math.max(along.abs() - l / 2, 0.0);
  return math.sqrt(ox * ox + oy * oy);
}

/// Rotate a point [p] around [pivot] by [angle] radians.
Vector2 rotateAround(Vector2 p, Vector2 pivot, double angle) {
  final dx = p.x - pivot.x;
  final dy = p.y - pivot.y;
  final cos = math.cos(angle);
  final sin = math.sin(angle);
  return Vector2(
    pivot.x + dx * cos - dy * sin,
    pivot.y + dx * sin + dy * cos,
  );
}

/// Random double in [min, max].
double randomRange(math.Random rng, double min, double max) =>
    min + rng.nextDouble() * (max - min);
