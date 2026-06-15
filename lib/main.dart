import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/maneuver.dart';
import 'input/hud_controls.dart';
import 'rules/exam_error_log.dart';
import 'tiles/tile_registry.dart';
import 'tiles/definitions/straight_tile.dart';
import 'tiles/definitions/intersection_tile.dart';
import 'traffic_game.dart';
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
  IntersectionTile.register();

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
            return MaterialPageRoute(
              builder: (_) => GameScreen(
                testMode: testMode,
                testManeuver: testManeuver,
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
  const GameScreen({super.key, this.testMode, this.testManeuver});

  final TileType? testMode;
  final Maneuver? testManeuver;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late TrafficGame _game;

  TrafficGame _buildGame() => TrafficGame(
        testMode: widget.testMode,
        testManeuver: widget.testManeuver,
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
          const ManeuverHud(),
        ],
      ),
    );
  }
}
