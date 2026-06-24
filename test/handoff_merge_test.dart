import 'dart:math' as math;
import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/cars/player_car.dart';
import 'package:traffic_game/input/input_state.dart';
import 'package:traffic_game/pedestrians/pedestrian.dart';
import 'package:traffic_game/tiles/tile_manager.dart';
import 'package:traffic_game/tiles/tile_registry.dart';
import 'package:traffic_game/tiles/definitions/straight_tile.dart';

/// REGRESSION GUARD for the mid-merge tile-seam jump.
///
/// `_nearestLateral` used to decide "am I past this lane?" from the COARSE nearest
/// sample, which snaps to the t=1 endpoint within ~1/24 of the end — so in the last ~4%
/// of a lane (right before a tile seam) the merge thought the neighbour vanished, the
/// cap collapsed to kIntentionLean, and the clamp slammed a still-merging car ~17px
/// sideways as it "entered the next tile". Now "past the lane" is a projection test, and
/// the hand-off carries the lean across the seam. This drives the REAL manager through
/// several seams while the merge is deliberately still in progress at each one, and
/// asserts there is no single-frame lateral snap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    StraightTile.register();
  });
  tearDown(InputState.instance.reset);

  test('a merge still in progress at a tile seam crosses with no jump', () {
    final player = PlayerCar();
    final tm = TileManager(
      playerCar: player,
      world: World(),
      pedestrians: <Pedestrian>[],
      ambientPedestrians: <Pedestrian>[],
      testMode: TileType.straight,
    );
    tm.bootstrap();
    player.speed = kmhToUnits(40);
    InputState.instance.setGasLevel(1.0);

    var prev = player.position.clone();
    var prevTile = tm.activeTile;
    var maxJump = 0.0;
    var handoffs = 0;
    var sawMidMergeSeam = false;
    for (int i = 0; i < 6000 && handoffs < 3; i++) {
      // Drag right ONLY in the last stretch of each tile, so the lane change is still
      // mid-flight when we cross the seam (a settled offset=0 crossing is trivially
      // continuous; the bug was the mid-merge crossing).
      InputState.instance.setLaneSteer(player.currentT > 0.86 ? 200.0 : -200.0);
      player.update(1 / 60);
      tm.update(1 / 60);
      final perp = Vector2(-math.sin(player.angle), math.cos(player.angle));
      final lat = (player.position - prev).dot(perp).abs();
      if (i > 2 && lat > maxJump) maxJump = lat; // skip the first settling frames
      if (!identical(tm.activeTile, prevTile)) {
        handoffs++;
        if (player.lateralOffset.abs() > kIntentionLean) sawMidMergeSeam = true;
      }
      prev = player.position.clone();
      prevTile = tm.activeTile;
    }

    expect(handoffs, greaterThanOrEqualTo(2), reason: 'drove across several seams');
    expect(sawMidMergeSeam, isTrue,
        reason: 'at least one seam was crossed mid-merge (offset > the lean cap)');
    expect(maxJump, lessThan(4),
        reason: 'no single-frame lateral snap anywhere, including the last 4% + the seam');
  });
}
