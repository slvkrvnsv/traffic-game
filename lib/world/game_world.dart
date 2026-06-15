import 'package:flame/components.dart';
import '../cars/player_car.dart';
import '../core/maneuver.dart';
import '../pedestrians/pedestrian.dart';
import '../rules/exam_error_recorder.dart';
import '../rules/rule_validator.dart';
import '../rules/violation_detector.dart';
import '../tiles/tile_manager.dart';
import '../tiles/tile_registry.dart';

/// Root world component. Owns the tile manager, player car, and rule system.
///
/// All mutable game registries (NPCs via [TileManager], pedestrians here) are
/// instance-scoped to this world, so a restart — which builds a fresh
/// [GameWorld] — starts from a clean slate with no manual clearing.
class GameWorld extends World {
  GameWorld({this.testMode, this.testManeuver});

  final TileType? testMode;
  final Maneuver? testManeuver;

  late final PlayerCar playerCar;
  late final TileManager tileManager;
  late final ViolationDetector violationDetector;
  late final RuleValidator ruleValidator;

  /// All live pedestrians in this world (see PedestrianSpawner).
  final List<Pedestrian> pedestrians = [];

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    playerCar = PlayerCar();
    add(playerCar);

    tileManager = TileManager(
      playerCar: playerCar,
      world: this,
      testMode: testMode,
      testManeuver: testManeuver,
    );
    add(tileManager);

    violationDetector = ViolationDetector(
      playerCar: playerCar,
      tileManager: tileManager,
      pedestrians: pedestrians,
    );
    add(violationDetector);

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
