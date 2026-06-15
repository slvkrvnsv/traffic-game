import 'package:flutter/foundation.dart';

/// Singleton that holds the current state of the player's touch controls.
/// The Flutter HUD widget writes to this; the Flame game reads from it.
class InputState extends ChangeNotifier {
  InputState._();
  static final InputState instance = InputState._();

  double _gasLevel = 0.0;   // 0.0 = off, 1.0 = full throttle
  double _brakeLevel = 0.0; // 0.0 = off, 1.0 = full braking

  /// Analog lane steering. While the player drags horizontally, [_laneSteerPx]
  /// holds the signed finger displacement (logical px, + = right) past the
  /// deadzone and [_laneSteerActive] is true. On release it goes inactive and
  /// the car settles onto its current lane. PlayerCar reads these each frame.
  double _laneSteerPx = 0.0;
  bool _laneSteerActive = false;

  double get gasLevel => _gasLevel;
  double get brakeLevel => _brakeLevel;

  double get laneSteerPx => _laneSteerPx;
  bool get laneSteerActive => _laneSteerActive;

  /// Update the live lane-steer displacement from a horizontal drag.
  void setLaneSteer(double px) {
    _laneSteerPx = px;
    _laneSteerActive = true;
  }

  /// End the current lane-steer gesture; the car settles onto its lane.
  void endLaneSteer() {
    _laneSteerActive = false;
    _laneSteerPx = 0.0;
  }

  void setGasLevel(double level) {
    final clamped = level.clamp(0.0, 1.0);
    if (_gasLevel == clamped) return;
    _gasLevel = clamped;
    notifyListeners();
  }

  void setBrakeLevel(double level) {
    final clamped = level.clamp(0.0, 1.0);
    if (_brakeLevel == clamped) return;
    _brakeLevel = clamped;
    notifyListeners();
  }

  void reset() {
    _gasLevel = 0.0;
    _brakeLevel = 0.0;
    _laneSteerPx = 0.0;
    _laneSteerActive = false;
    notifyListeners();
  }
}
