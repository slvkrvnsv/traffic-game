import 'dart:async';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'core/constants.dart';
import 'core/game_bus.dart';
import 'debug/debug_state.dart';
import 'core/maneuver.dart';
import 'input/input_state.dart';
import 'tiles/tile_registry.dart';
import 'world/camera_controller.dart';
import 'world/game_world.dart';

/// Root Flame game.
class TrafficGame extends FlameGame {
  TrafficGame(
      {this.testMode,
      this.testManeuver,
      this.testSequence,
      this.testLocale,
      this.testControl});

  /// If set, loop this tile type in test mode.
  final TileType? testMode;

  /// If set, pin the commanded maneuver on every tile (test mode).
  final Maneuver? testManeuver;

  /// If set, loop this ordered sequence of tile types (test mode course).
  final List<TileType>? testSequence;

  /// If set, dress every tile as this locale (test mode).
  final LocaleType? testLocale;

  /// If set, pin every intersection's control (test mode): stop or light.
  final IntersectionControl? testControl;

  late final GameWorld _world;
  late final CameraController _cameraController;
  late StreamSubscription<GameOverEvent> _gameOverSub;

  String? _pendingGameOverReason;

  @override
  Color backgroundColor() => const Color(0xFF1A1A2E);

  @override
  Future<void> onLoad() async {
    // Tiles are registered once at app startup in main.dart.
    // Clear the touch controls so a held pedal or armed blinker never carries
    // over from the previous game (restart rebuilds the whole TrafficGame).
    InputState.instance.reset();
    DebugState.showDebug = testMode != null || testSequence != null;

    // Build world + camera
    _world = GameWorld(
        testMode: testMode,
        testManeuver: testManeuver,
        testSequence: testSequence,
        testLocale: testLocale,
        testControl: testControl);

    final camera = CameraComponent(world: _world)
      ..viewfinder.zoom = kCameraZoom
      ..viewfinder.anchor = Anchor.center;

    await addAll([_world, camera]);

    _cameraController = CameraController(
      camera: camera,
      playerCar: _world.playerCar,
    );
    await add(_cameraController);

    // Listen for game over
    _gameOverSub = GameBus.instance.on<GameOverEvent>().listen((e) {
      _pendingGameOverReason = e.reason;
      overlays.add('gameOver');
      pauseEngine();
    });
  }

  // Restart is handled by recreating the whole TrafficGame instance
  // (see _GameScreenState._restart in main.dart) — the single restart path.

  String? get gameOverReason => _pendingGameOverReason;

  @override
  void onRemove() {
    _gameOverSub.cancel();
    super.onRemove();
  }
}
