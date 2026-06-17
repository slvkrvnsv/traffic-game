import 'dart:async';
import '../feedback/driver_reaction.dart';
import '../rules/exam_error.dart';
import 'maneuver.dart';

// ---------------------------------------------------------------------------
// Event hierarchy (sealed)
// ---------------------------------------------------------------------------

sealed class GameEvent {}

/// Player crashed into an NPC car or pedestrian.
class CollisionEvent extends GameEvent {
  CollisionEvent({required this.otherType});
  final String otherType; // 'npc_car' | 'pedestrian'
}

/// Player blew through a yield line at unsafe speed.
class YieldViolationEvent extends GameEvent {
  YieldViolationEvent({required this.speedAtLine});
  final double speedAtLine;
}

/// Player did not stop fully at a stop-sign line.
class StopSignViolationEvent extends GameEvent {
  StopSignViolationEvent({required this.minSpeedObserved});
  final double minSpeedObserved;
}

/// Player crossed a red light.
class RedLightViolationEvent extends GameEvent {}

/// Player sat still on a clear road with no reason to wait — blocking traffic.
class RoadBlockingEvent extends GameEvent {
  RoadBlockingEvent({required this.duration});
  final double duration;
}

/// An NPC driver reacted to something the player did to them (e.g. a cut-off
/// that forced a hard brake). Data-only — carries the reaction kind and where
/// it happened, never a live car reference, so it stays safe to record/serialise.
/// The visible bubble is spawned directly by the detector; this event is the
/// decoupled hook for future scoring / fault-sheet integration.
class DriverReactionEvent extends GameEvent {
  DriverReactionEvent({required this.reaction, required this.worldX, required this.worldY});
  final DriverReaction reaction;
  final double worldX;
  final double worldY;
}

/// A scenario task — the rule the player had to obey on the active tile —
/// was failed. Non-fatal: it's recorded as a fault for later review, never a
/// game-over (only a crash ends the run). Emitted once per scenario instance
/// on the failing edge by [RuleValidator], which owns the context-aware grading.
///
/// [kind] is the specific rule when the originating event names it
/// (yield/stop/red); null for scenario-specific faults (e.g. an unsafe merge),
/// which carry only the [reason] string. [speed] is the player speed at the
/// fault when relevant (e.g. crossing a yield line).
class ScenarioTaskFailedEvent extends GameEvent {
  ScenarioTaskFailedEvent({required this.reason, this.kind, this.speed});
  final String reason;
  final ExamErrorType? kind;
  final double? speed;
}

/// Positive confirmation — player correctly stopped / yielded.
class RulePassedEvent extends GameEvent {}

/// Tile was successfully completed.
class TileCompletedEvent extends GameEvent {
  TileCompletedEvent({required this.tileType});
  final String tileType;
}

/// Tile ready to be activated (next tile spawned).
class TileReadyEvent extends GameEvent {
  TileReadyEvent({required this.tileType});
  final String tileType;
}

/// Game over — includes reason string for the UI.
class GameOverEvent extends GameEvent {
  GameOverEvent({required this.reason});
  final String reason;
}

/// Player's car was handed off to the next tile's spline.
class PlayerHandOffEvent extends GameEvent {}

/// The exam instruction for the tile the player just entered.
/// [maneuver] is null on tiles with no instruction (plain road) — HUD hides.
/// [label] overrides the maneuver's text for instructions that aren't one of
/// the intersection maneuvers (e.g. "Merge left" on a lane-transition tile);
/// null falls back to [maneuver].label.
class ManeuverAnnouncedEvent extends GameEvent {
  ManeuverAnnouncedEvent({required this.maneuver, this.label});
  final Maneuver? maneuver;
  final String? label;
}

// ---------------------------------------------------------------------------
// Bus
// ---------------------------------------------------------------------------

/// Global typed event bus. Decouple systems; no direct references needed.
///
/// Usage:
///   GameBus.instance.emit(CollisionEvent(otherType: 'npc_car'));
///   GameBus.instance.on`<CollisionEvent>`().listen((e) { ... });
class GameBus {
  GameBus._();
  static final GameBus instance = GameBus._();

  final StreamController<GameEvent> _controller =
      StreamController<GameEvent>.broadcast();

  Stream<GameEvent> get stream => _controller.stream;

  void emit(GameEvent event) => _controller.add(event);

  /// Filtered stream for a specific event type.
  Stream<T> on<T extends GameEvent>() =>
      _controller.stream.where((e) => e is T).cast<T>();

  void dispose() => _controller.close();
}
