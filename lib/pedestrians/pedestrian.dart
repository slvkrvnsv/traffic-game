import 'dart:ui';
import 'package:flame/components.dart';
import '../core/constants.dart';
import '../core/spline.dart';
import '../core/spline_follower.dart';

/// A pedestrian that walks a spline (a sidewalk route that may cross a road).
class Pedestrian extends PositionComponent with SplineFollower {
  Pedestrian({
    required Spline crossingPath,
    required this.walkSpeed,
    required this.color,
    required this.skinColor,
    required this.hairColor,
    Vector2? worldOffset,
    double worldAngle = 0.0,
  }) : super(
          size: Vector2(22, 22),
          anchor: Anchor.center,
          priority: kPedestrianPriority,
        ) {
    // Splines are authored tile-local; the pedestrian is a world child, so it
    // carries the owning tile's placement (like NPC cars do).
    assignSpline(crossingPath, worldOffset: worldOffset, worldAngle: worldAngle);
    position.setFrom(splinePosition);
    angle = splineAngle;
  }

  final double walkSpeed;

  /// Shirt/body colour.
  final Color color;

  /// Skin tone for the head.
  final Color skinColor;

  /// Hair colour, or null for bald (head shows skin).
  final Color? hairColor;

  // Set each frame by TileManager: a car's bounding box is on the next step.
  // The pedestrian respects it — it holds rather than walking into the box.
  bool _blockedByPlayer = false;
  bool _blockedByNpc = false;
  double _holdTime = 0.0;

  // Set each frame by TileManager: the player's car body is inside this
  // pedestrian's personal-space bubble. Tracked so the startle "!" pops once per
  // intrusion (rising edge), independent of whether the car blocks the next step.
  bool _startledByPlayer = false;

  void setBlocked({required bool player, required bool npc}) {
    _blockedByPlayer = player;
    _blockedByNpc = npc;
  }

  /// Whether the player's car is currently inside this pedestrian's personal
  /// space. Carries the previous frame's value for the rising-edge startle cue.
  bool get startledByPlayer => _startledByPlayer;
  void setStartled(bool value) => _startledByPlayer = value;

  /// Whether the player's car is currently in this pedestrian's path, so the
  /// pedestrian is held for it. This is the ground truth for "the player forced
  /// this pedestrian to stop" — the real-world give-way fault keys off it (see
  /// `IntersectionTile`), instead of any reach/clearance geometry.
  bool get blockedByPlayer => _blockedByPlayer;

  bool get hasCrossed => hasReachedEnd;

  @override
  void update(double dt) {
    super.update(dt);
    if (!_blockedByNpc) _holdTime = 0.0;
    bool hold;
    if (_blockedByPlayer) {
      hold = true; // never walk through the player (no unfair crash)
    } else if (_blockedByNpc) {
      _holdTime += dt;
      hold = _holdTime < kPedHoldTimeout; // break a rare mutual stand-off
    } else {
      hold = false;
    }
    if (!hold) advanceByDistance(walkSpeed * dt);
    position.setFrom(splinePosition);
    angle = splineAngle;
  }

  @override
  void render(Canvas canvas) {
    // Flame's render origin is the top-left corner; translate to the centre so
    // the figure sits on the pedestrian's real position (matches CarBase).
    canvas.translate(size.x / 2, size.y / 2);

    // GTA-classic top-down: looking straight down. Shoulders are a rounded body
    // (wider across travel than front-to-back); the head a centred circle on
    // top, hair covering all but a sliver of face at the front; a tiny nose
    // marks facing. Forward = local +x (the car convention).
    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, 1), width: 15, height: 18),
      Paint()..color = const Color(0x33000000),
    );
    // Shoulders (shirt) — long axis across the direction of travel (y).
    final body = Rect.fromCenter(center: Offset.zero, width: 12, height: 16);
    canvas.drawOval(body, Paint()..color = color);
    canvas.drawOval(
      body,
      Paint()
        ..color = const Color(0x55000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    // Head — skin circle (the face shows at the front).
    canvas.drawCircle(Offset.zero, 5.4, Paint()..color = skinColor);
    // Hair — a slightly smaller circle nudged toward the back (−x), leaving the
    // forehead/face as skin. Skipped when bald.
    if (hairColor != null) {
      canvas.drawCircle(
          const Offset(-1.4, 0), 4.8, Paint()..color = hairColor!);
    }
    // Nose / facing nub just ahead of the head (local +x).
    canvas.drawCircle(const Offset(5.0, 0), 1.8, Paint()..color = skinColor);
  }
}
