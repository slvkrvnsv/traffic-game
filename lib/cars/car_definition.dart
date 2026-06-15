import 'package:flutter/material.dart';

/// Immutable data describing one car model's visual style.
/// All cars share the same hitbox (kCarLength × kCarWidth) for collision.
class CarDefinition {
  const CarDefinition({
    required this.id,
    required this.bodyColor,
    required this.roofColor,
    required this.lengthRatio, // multiplier on kCarLength for the visual body
    required this.widthRatio,  // multiplier on kCarWidth for the visual body
  });

  final String id;
  final Color bodyColor;
  final Color roofColor;
  final double lengthRatio;
  final double widthRatio;
}
