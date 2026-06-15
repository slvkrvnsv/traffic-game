import '../../core/constants.dart';
import 'npc_state_base.dart';

/// Gap-keeping behind the car ahead.
///
/// Uses a speed-dependent desired headway so fast cars leave a longer gap.
/// Speed is linearly mapped between 0 (at [emergencyGap]) and profileSpeed
/// (at [desiredGap]).  The collision-avoidance overlay in NpcBrain provides
/// an additional safety net on top of this.
class StateFollowing extends NpcState {
  static const double _headwaySeconds = 0.8; // desired time gap

  @override
  double update(double dt, NpcSensors s) {
    final gap = s.leadCarDistance;
    if (gap == null) return s.profileSpeed;

    // Emergency gap: one car length bumper-to-bumper.
    const emergencyGap = kCarLength;
    // Desired gap grows with speed so the NPC has room to brake.
    final desiredGap = kNpcSafeGapDistance + s.currentSpeed * _headwaySeconds;

    if (gap <= emergencyGap) return 0.0;

    // Linear ramp: 0 at emergencyGap → profileSpeed at desiredGap.
    final fraction = ((gap - emergencyGap) / (desiredGap - emergencyGap))
        .clamp(0.0, 1.0);
    return s.profileSpeed * fraction;
  }
}
