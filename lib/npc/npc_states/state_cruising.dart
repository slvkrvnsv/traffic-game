import 'npc_state_base.dart';

/// Normal travel at profile speed.
class StateCruising extends NpcState {
  @override
  double update(double dt, NpcSensors s) {
    // Sensor checks are handled by NpcBrain; here we just set desired speed.
    return s.profileSpeed;
  }
}
