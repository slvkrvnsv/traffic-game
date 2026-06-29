import 'package:flame/components.dart';
import '../cars/player_car.dart';
import '../core/game_bus.dart';
import '../core/maneuver.dart';
import '../feedback/driver_reaction_detector.dart';
import '../pedestrians/pedestrian.dart';
import '../rules/exam_error_recorder.dart';
import '../rules/rule_validator.dart';
import '../rules/violation_detector.dart';
import '../tiles/tile_manager.dart';
import '../tiles/tile_registry.dart';
import 'signal_head_overlay.dart';

/// Root world component. Owns the tile manager, player car, and rule system.
///
/// All mutable game registries (NPCs via [TileManager], pedestrians here) are
/// instance-scoped to this world, so a restart — which builds a fresh
/// [GameWorld] — starts from a clean slate with no manual clearing.
class GameWorld extends World {
  GameWorld(
      {this.testMode,
      this.testManeuver,
      this.testSequence,
      this.testLocale,
      this.testControl});

  final TileType? testMode;
  final Maneuver? testManeuver;
  final List<TileType>? testSequence;

  /// If set, pin every tile to this locale (test mode). Null → free-drive rolls
  /// it in stretches (see TileManager).
  final LocaleType? testLocale;

  /// If set, pin every intersection's control (test mode): stop or light.
  final IntersectionControl? testControl;

  late final PlayerCar playerCar;
  late final TileManager tileManager;
  late final ViolationDetector violationDetector;
  late final RuleValidator ruleValidator;

  /// Rule-relevant pedestrians (road crossings) — scanned by ViolationDetector
  /// for collisions and road-block clearance.
  final List<Pedestrian> pedestrians = [];

  /// Ambient sidewalk walkers — visual only, deliberately NOT scanned by the
  /// rules system (clipping a sidewalk must never end the run, and they must not
  /// register as a reason to wait on a clear road).
  final List<Pedestrian> ambientPedestrians = [];

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // New game → new bus generation, so any leaked listeners from a previous
    // (restarted) game go inert before this game's components subscribe.
    GameBus.instance.newGeneration();

    playerCar = PlayerCar();
    add(playerCar);

    tileManager = TileManager(
      playerCar: playerCar,
      world: this,
      pedestrians: pedestrians,
      ambientPedestrians: ambientPedestrians,
      testMode: testMode,
      testManeuver: testManeuver,
      testSequence: testSequence,
      testLocale: testLocale,
      testControl: testControl,
    );
    add(tileManager);

    // Overhead signal heads paint above the cars (the tile layer is underneath
    // them), so a car stopped at a light can't cover the head it's waiting on.
    add(SignalHeadOverlay(tileManager: tileManager));

    violationDetector = ViolationDetector(
      playerCar: playerCar,
      tileManager: tileManager,
      pedestrians: pedestrians,
    );
    add(violationDetector);

    // NPC driver reactions (red bubble when the player cuts someone off). Purely
    // additive feedback — does not affect the fail model.
    add(DriverReactionDetector(
      playerCar: playerCar,
      tileManager: tileManager,
      world: this,
    ));

    ruleValidator = RuleValidator();
    // Evaluate rule events against the scenario for the tile the player is on.
    ruleValidator.bindScenarioSource(() => tileManager.activeTile?.scenario);
    add(ruleValidator);

    // Record every rule-break as an exam error (tracking only — the fail
    // model is untouched).
    add(ExamErrorRecorder(tileManager: tileManager));

    // Bootstrap generates the first tiles
    tileManager.bootstrap();
  }
}
