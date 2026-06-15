import 'npc_state_base.dart';

/// Yielding at an intersection. The brain's stop-line cap (active while we
/// lack right-of-way) decelerates us to a precise halt at the painted line and
/// holds us there; this state just expresses the intent to proceed. Once we
/// regain right-of-way the cap clears and the brain transitions out.
class StateYielding extends NpcState {
  @override
  double update(double dt, NpcSensors s) {
    return s.profileSpeed;
  }
}
