import 'package:flutter/material.dart';
import 'car_definition.dart';

/// The four available car models.
class CarVariants {
  CarVariants._();

  static const CarDefinition sedan = CarDefinition(
    id: 'sedan',
    bodyColor: Color(0xFF3A7BD5),
    roofColor: Color(0xFF2C5FAA),
    lengthRatio: 1.0,
    widthRatio: 1.0,
  );

  static const CarDefinition hatchback = CarDefinition(
    id: 'hatchback',
    bodyColor: Color(0xFFE53935),
    roofColor: Color(0xFFB71C1C),
    lengthRatio: 0.88,
    widthRatio: 0.95,
  );

  static const CarDefinition suv = CarDefinition(
    id: 'suv',
    bodyColor: Color(0xFF43A047),
    roofColor: Color(0xFF2E7D32),
    lengthRatio: 1.12,
    widthRatio: 1.08,
  );

  static const CarDefinition van = CarDefinition(
    id: 'van',
    bodyColor: Color(0xFFFB8C00),
    roofColor: Color(0xFFE65100),
    lengthRatio: 1.25,
    widthRatio: 1.05,
  );

  static const List<CarDefinition> all = [sedan, hatchback, suv, van];

  /// Player's car (distinct yellow).
  static const CarDefinition player = CarDefinition(
    id: 'player',
    bodyColor: Color(0xFFFFD600),
    roofColor: Color(0xFFC6A800),
    lengthRatio: 1.0,
    widthRatio: 1.0,
  );
}
