import 'dart:math' as math;
import 'package:flame/components.dart';
import '../core/constants.dart';
import '../core/utils.dart';
import '../cars/player_car.dart';

/// Smooth top-down camera that follows the player car and rotates with it,
/// keeping the car pointed "up" on screen while the world spins underneath.
/// Applies a look-ahead offset in the direction of travel.
class CameraController extends Component {
  CameraController({
    required this.camera,
    required this.playerCar,
  });

  final CameraComponent camera;
  final PlayerCar playerCar;

  /// Heading used for both the look-ahead and the camera rotation, eased toward
  /// the car's heading so the view swings gently through a turn instead of
  /// snapping. null until the first frame seeds it from the car's heading.
  ///
  /// Tracks [PlayerCar.splineAngle] — the lane/corridor direction — rather than
  /// the full body angle, so the camera rotates through actual turns but stays
  /// steady during a lane change (the body yaw is ignored).
  double? _smoothedAngle;

  @override
  void update(double dt) {
    super.update(dt);

    _smoothedAngle = _smoothedAngle == null
        ? playerCar.splineAngle
        : lerpAngle(_smoothedAngle!, playerCar.splineAngle, kCameraLookAheadLerpSpeed * dt);
    final angle = _smoothedAngle!;
    final lookAhead = Vector2(
      kCameraForwardOffset * math.cos(angle),
      kCameraForwardOffset * math.sin(angle),
    );
    final target = playerCar.position + lookAhead;

    // Lerp camera toward target
    final current = camera.viewfinder.position;
    camera.viewfinder.position = Vector2(
      lerp(current.x, target.x, kCameraLerpSpeed * dt),
      lerp(current.y, target.y, kCameraLerpSpeed * dt),
    );

    // Rotate the world so the car stays pointing up. A world heading `a` renders
    // on screen at `a - viewfinder.angle`; screen-up is -pi/2, so angle = a + pi/2.
    camera.viewfinder.angle = angle + math.pi / 2;
  }
}
