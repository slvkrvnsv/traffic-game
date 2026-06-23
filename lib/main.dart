import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/maneuver.dart';
import 'input/hud_controls.dart';
import 'rules/exam_error_log.dart';
import 'tiles/tile_registry.dart';
import 'tiles/definitions/straight_tile.dart';
import 'tiles/definitions/straight_one_lane_tile.dart';
import 'tiles/definitions/lane_transition_tile.dart';
import 'tiles/definitions/intersection_tile.dart';
import 'tiles/definitions/start_tile.dart';
import 'traffic_game.dart';
import 'ui/fault_log_hud.dart';
import 'ui/game_over_overlay.dart';
import 'ui/main_menu.dart';
import 'ui/maneuver_hud.dart';
import 'ui/speedometer_hud.dart';
import 'ui/test_menu.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Register all tile types once at startup so TestMenuScreen can list them
  // before any TrafficGame instance is created.
  StraightTile.register();
  StraightOneLaneTile.register();
  LaneTransitionTile.register();
  IntersectionTile.register();
  StartTile.register();

  // Restore the persisted exam-error history (fault sheet).
  await ExamErrorLog.instance.load();

  runApp(const TrafficApp());
}

class TrafficApp extends StatelessWidget {
  const TrafficApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Traffic Rules',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(
              builder: (_) => const MainMenuScreen(),
            );
          case '/test':
            return MaterialPageRoute(
              builder: (_) => const TestMenuScreen(),
            );
          case '/game':
            final args = settings.arguments as Map<String, dynamic>?;
            final testMode = args?['testMode'] as TileType?;
            final testManeuver = args?['testManeuver'] as Maneuver?;
            final testSequence = args?['testSequence'] as List<TileType>?;
            final testLocale = args?['testLocale'] as LocaleType?;
            final testControl = args?['testControl'] as IntersectionControl?;
            return MaterialPageRoute(
              builder: (_) => GameScreen(
                testMode: testMode,
                testManeuver: testManeuver,
                testSequence: testSequence,
                testLocale: testLocale,
                testControl: testControl,
              ),
            );
          default:
            return MaterialPageRoute(
              builder: (_) => const MainMenuScreen(),
            );
        }
      },
    );
  }
}

/// The game screen: Flame GameWidget + Flutter HUD overlay.
class GameScreen extends StatefulWidget {
  const GameScreen(
      {super.key,
      this.testMode,
      this.testManeuver,
      this.testSequence,
      this.testLocale,
      this.testControl});

  final TileType? testMode;
  final Maneuver? testManeuver;
  final List<TileType>? testSequence;
  final LocaleType? testLocale;
  final IntersectionControl? testControl;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late TrafficGame _game;

  TrafficGame _buildGame() => TrafficGame(
        testMode: widget.testMode,
        testManeuver: widget.testManeuver,
        testSequence: widget.testSequence,
        testLocale: widget.testLocale,
        testControl: widget.testControl,
      );

  @override
  void initState() {
    super.initState();
    _game = _buildGame();
  }

  void _restart() {
    setState(() {
      _game = _buildGame();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          GameWidget(
            game: _game,
            overlayBuilderMap: {
              'gameOver': (context, game) {
                final g = game as TrafficGame;
                return GameOverOverlay(
                  reason: g.gameOverReason ?? 'Something went wrong.',
                  onRetry: _restart,
                );
              },
            },
          ),
          const HudControls(),
          const SpeedometerHud(),
          const FaultLogHud(),
          const ManeuverHud(),
        ],
      ),
    );
  }
}
