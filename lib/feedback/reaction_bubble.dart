import 'dart:math' as math;
import 'dart:ui';
import 'package:flame/components.dart';
import '../cars/npc_car.dart';
import '../cars/player_car.dart';
import 'driver_reaction.dart';

/// A short-lived speech bubble drawn above an NPC that reacted to the player.
///
/// Lives in world space as a child of the world (NOT of the NPC): the camera
/// rotates to keep the player pointing up, so a child-of-NPC bubble would flip
/// upside-down on oncoming cars. Instead it each frame:
///   • follows the NPC,
///   • offsets toward screen-up (the player's heading, which the camera maps to
///     up) so it sits above the car, and
///   • sets its own angle to the camera's view angle so the icon stays upright
///     at every heading.
/// It pops in, holds, fades out, and removes itself (or vanishes immediately if
/// its NPC is culled).
class ReactionBubble extends PositionComponent {
  ReactionBubble({
    required this.target,
    required this.player,
    required this.reaction,
  })  : _remaining = reaction.duration,
        super(
          size: Vector2(54, 46),
          anchor: Anchor.center,
          priority: 100, // above cars (5/10)
        );

  final NpcCar target;
  final PlayerCar player;
  final DriverReaction reaction;

  double _remaining;

  static const double _popTime = 0.12; // grow-in duration
  static const double _fadeTime = 0.4; // fade-out window at the end
  static const double _offset = 44.0; // world units above the car

  @override
  void update(double dt) {
    super.update(dt);
    _remaining -= dt;
    if (_remaining <= 0 || target.isRemoved || target.parent == null) {
      removeFromParent();
      return;
    }
    // Screen-up in world coordinates is the player's heading (camera points the
    // player up). Offsetting along it puts the bubble above the car on screen.
    final a = player.splineAngle;
    position
      ..setFrom(target.position)
      ..x += math.cos(a) * _offset
      ..y += math.sin(a) * _offset;
    // Counter-rotate to the camera's view angle so the bubble renders upright.
    angle = a + math.pi / 2;
  }

  @override
  void render(Canvas canvas) {
    final elapsed = reaction.duration - _remaining;
    final pop = (elapsed / _popTime).clamp(0.0, 1.0);
    final scale = 0.6 + 0.4 * pop; // ease from 60% → 100%
    final alpha = (_remaining / _fadeTime).clamp(0.0, 1.0);

    canvas.translate(size.x / 2, size.y / 2);
    canvas.scale(scale);

    final color = reaction.color.withValues(alpha: alpha);
    final white = const Color(0xFFFFFFFF).withValues(alpha: alpha);

    // Bubble body — rounded rect with a small tail pointing down at the car.
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: const Offset(0, -4), width: 48, height: 36),
      const Radius.circular(12),
    );
    final tail = Path()
      ..moveTo(-7, 12)
      ..lineTo(7, 12)
      ..lineTo(0, 22)
      ..close();
    final fill = Paint()..color = color;
    canvas.drawRRect(body, fill);
    canvas.drawPath(tail, fill);

    // White exclamation mark, drawn as shapes (no font dependency, always crisp).
    final mark = Paint()..color = white;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(0, -8), width: 6, height: 16),
        const Radius.circular(3),
      ),
      mark,
    );
    canvas.drawCircle(const Offset(0, 6), 3.4, mark);
  }
}
