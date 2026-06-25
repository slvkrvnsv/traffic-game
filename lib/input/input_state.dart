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

  /// Manual turn signal: -1 = left, 0 = off, +1 = right (the two sides are
  /// mutually exclusive). The player arms it from the HUD blinker buttons and
  /// PlayerCar mirrors it onto its indicators each frame. There is no automatic
  /// or curvature-based signalling for the player any more — this field is the
  /// single source of truth for the player's blinker.
  int _turnSignal = 0;

  double get gasLevel => _gasLevel;
  double get brakeLevel => _brakeLevel;

  double get laneSteerPx => _laneSteerPx;
  bool get laneSteerActive => _laneSteerActive;

  int get turnSignal => _turnSignal;

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

  /// Flick the blinker for [dir] (-1 = left, +1 = right): arms that side, or
  /// turns it off again if it was already armed. Arming one side cancels the
  /// other, so the two are always mutually exclusive.
  void toggleSignal(int dir) {
    final next = (_turnSignal == dir) ? 0 : dir;
    if (_turnSignal == next) return;
    _turnSignal = next;
    notifyListeners();
  }

  /// Force the blinker off — used by the car's self-cancel once a turn in the
  /// signalled direction has been completed (the real-life stalk snap-back).
  void clearSignal() {
    if (_turnSignal == 0) return;
    _turnSignal = 0;
    notifyListeners();
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
    _turnSignal = 0;
    notifyListeners();
  }
}
