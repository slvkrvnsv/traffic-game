import 'npc_state_base.dart';

/// Stopped at a red light; resumes when green.
class StateWaitingLight extends NpcState {
  @override
  double update(double dt, NpcSensors s) {
    return s.isRedLight ? 0.0 : s.profileSpeed * 0.4; // ease away from line
  }
}
