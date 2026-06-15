import 'npc_state_base.dart';

/// Blinking turn indicator before a turn. Maintains current cruise speed.
class StateSignaling extends NpcState {
  @override
  double update(double dt, NpcSensors s) {
    return s.profileSpeed; // keep cruising while signalling
  }
}
