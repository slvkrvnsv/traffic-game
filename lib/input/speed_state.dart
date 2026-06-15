import 'package:flutter/foundation.dart';
import '../core/constants.dart';

/// Singleton that bridges the Flame game loop to the Flutter HUD speedometer.
/// PlayerCar writes here each frame; SpeedometerHud listens via ValueNotifier.
class SpeedState {
  SpeedState._();
  static final SpeedState instance = SpeedState._();

  final ValueNotifier<double> speedKmh = ValueNotifier(0.0);

  void updateFromUnits(double unitsPerSecond) {
    speedKmh.value = unitsPerSecond * kSpeedToKmh;
  }
}
