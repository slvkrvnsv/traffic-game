import 'package:flutter/foundation.dart';

/// Singleton that holds the current state of the player's touch controls.
/// The Flutter HUD widget writes to this; the Flame game reads from it.
class InputState extends ChangeNotifier {
  InputState._();
  static final InputState instance = InputState._();

  double _gasLevel = 0.0;   // 0.0 = off, 1.0 = full throttle
  double _brakeLevel = 0.0; // 0.0 = off, 1.0 = full braking

  double get gasLevel => _gasLevel;
  double get brakeLevel => _brakeLevel;

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
    notifyListeners();
  }
}
