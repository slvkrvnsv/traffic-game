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

/// Player forced a pedestrian crossing — drove through while someone was on the
/// zebra without yielding. Non-fatal (logged exam fault); actually hitting them
/// is a separate [CollisionEvent] that ends the run.
class PedestrianYieldViolationEvent extends GameEvent {
  PedestrianYieldViolationEvent({required this.speedAtLine});
  final double speedAtLine;
}

/// Player did not stop fully at a stop-sign line.
class StopSignViolationEvent extends GameEvent {
  StopSignViolationEvent({required this.minSpeedObserved});
  final double minSpeedObserved;
}

/// Player crossed a red light.
class RedLightViolationEvent extends GameEvent {}

/// Player entered the box on a YELLOW they had room to stop for comfortably — the
/// "dilemma zone" exam fault (committing through a yellow you can't stop for is
/// fine). Non-fatal — a logged exam fault.
class YellowRunEvent extends GameEvent {}

/// Player stopped with the nose past the stop line on red — over the line / into
/// the crosswalk. Non-fatal — a logged exam fault.
class StopLineViolationEvent extends GameEvent {}

/// Player proceeded on green into a box cross traffic hadn't finished clearing —
/// "gunned the green" without making sure the junction was clear. Non-fatal.
class GunGreenEvent extends GameEvent {}

/// Player entered the conflict box in the wrong lane for the commanded maneuver
/// (a multi-lane intersection: e.g. turning left from a through/right lane, or
/// going straight from a left-turn-only lane). Non-fatal — a logged exam fault.
class WrongLaneEvent extends GameEvent {}

/// Player MISSED THE TURN — ended up somewhere other than the instruction (drove
/// straight, or took the other turn, instead of the commanded maneuver). The
/// headline task error: it fires whenever the OUTCOME is wrong, ahead of (and
/// regardless of) any lane error. Non-fatal — a logged exam fault.
class MissedTurnEvent extends GameEvent {}

/// Player turned into the far lane of the target road instead of the nearest
/// one (the US "turn into the closest lane" rule). Non-fatal — a logged fault.
class WrongExitLaneEvent extends GameEvent {}

/// Player changed lanes (or merged) without the turn signal armed that way.
/// Global — detected at the lane-change commit on any tile, not scenario-gated.
/// Non-fatal: a logged exam fault.
class LaneChangeWithoutSignalEvent extends GameEvent {
  LaneChangeWithoutSignalEvent({required this.speed});
  final double speed;
}

/// Player took a commanded turn without the turn signal armed that way. Global —
/// detected at the turn commit on any tile, not scenario-gated. Non-fatal: a
/// logged exam fault.
class TurnWithoutSignalEvent extends GameEvent {
  TurnWithoutSignalEvent({required this.speed});
  final double speed;
}

/// Player sat still on a clear road with no reason to wait — blocking traffic.
class RoadBlockingEvent extends GameEvent {
  RoadBlockingEvent({required this.duration});
  final double duration;
}

/// Player stopped inside the intersection box unable to clear it — stuck behind a
/// downstream queue, obstructing cross traffic ("don't block the box" / gridlock).
/// Distinct from [RoadBlockingEvent] (a clear road) and from a legitimate in-box
/// yield (clear exit). Non-fatal — a logged exam fault.
class BlockedIntersectionEvent extends GameEvent {}

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

  /// Monotonic id of the current game. The bus is a singleton that outlives a
  /// game restart, so listeners from a previous game can leak (their host
  /// components aren't always disposed by the widget swap). Each new world
  /// bumps this; per-game listeners snapshot it and go inert once stale, so a
  /// single event can't be handled once per leaked game (e.g. a stop fault
  /// recorded N times after N retries).
  int _generation = 0;
  int get generation => _generation;
  void newGeneration() => _generation++;

  void emit(GameEvent event) => _controller.add(event);

  /// Filtered stream for a specific event type.
  Stream<T> on<T extends GameEvent>() =>
      _controller.stream.where((e) => e is T).cast<T>();

  void dispose() => _controller.close();
}
