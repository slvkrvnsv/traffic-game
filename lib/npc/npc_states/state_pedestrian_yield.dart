import 'npc_state_base.dart';

/// Stopped for a pedestrian crossing.
class StatePedestrianYield extends NpcState {
  @override
  double update(double dt, NpcSensors s) {
    return s.pedestrianInPath ? 0.0 : s.profileSpeed * 0.3;
  }
}
