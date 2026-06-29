import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/maneuver.dart';
import 'package:traffic_game/tiles/definitions/lane_config.dart';

void main() {
  group('LaneConfig', () {
    test('L1: inner is left-only, outer is straight + right', () {
      expect(LaneConfig.l1.allows(isInner: true, m: Maneuver.left), isTrue);
      expect(LaneConfig.l1.allows(isInner: true, m: Maneuver.straight), isFalse);
      expect(LaneConfig.l1.allows(isInner: false, m: Maneuver.straight), isTrue);
      expect(LaneConfig.l1.allows(isInner: false, m: Maneuver.right), isTrue);
      expect(LaneConfig.l1.allows(isInner: false, m: Maneuver.left), isFalse);
    });

    test('commandable() is the union of both lanes', () {
      expect(LaneConfig.l1.commandable(),
          {Maneuver.left, Maneuver.straight, Maneuver.right});
      expect(LaneConfig.straightRightSplit.commandable(),
          {Maneuver.straight, Maneuver.right});
      expect(LaneConfig.sharedStraight.commandable(),
          {Maneuver.left, Maneuver.straight, Maneuver.right});
    });

    test('arrowKinds are in display order (left, up, right) and match the rule',
        () {
      expect(LaneConfig.l1.arrowKinds(isInner: true), ['left']);
      expect(LaneConfig.l1.arrowKinds(isInner: false), ['up', 'right']);
      expect(LaneConfig.straightRightSplit.arrowKinds(isInner: true), ['up']);
      expect(LaneConfig.straightRightSplit.arrowKinds(isInner: false), ['right']);
      expect(LaneConfig.sharedStraight.arrowKinds(isInner: true), ['left', 'up']);
      expect(LaneConfig.sharedStraight.arrowKinds(isInner: false), ['up', 'right']);
    });

    test('rejects a config beyond the drivable branch set (geometry ceiling)', () {
      // right has no branch on the inner spine; left none on the outer.
      expect(() => LaneConfig(inner: {Maneuver.right}, outer: {Maneuver.right}),
          throwsArgumentError);
      expect(() => LaneConfig(inner: {Maneuver.left}, outer: {Maneuver.left}),
          throwsArgumentError);
    });

    test('rejects an empty lane', () {
      expect(() => LaneConfig(inner: {}, outer: {Maneuver.right}),
          throwsArgumentError);
    });

    test('every preset constructs (is drivable) and commands something', () {
      expect(LaneConfig.presets, isNotEmpty);
      for (final c in LaneConfig.presets) {
        expect(c.commandable(), isNotEmpty);
      }
    });

    test('the added presets read as intended', () {
      // Turn-only: every command is a turn, each from its own lane.
      expect(LaneConfig.turnOnly.commandable(),
          {Maneuver.left, Maneuver.right});
      expect(LaneConfig.turnOnly.arrowKinds(isInner: true), ['left']);
      expect(LaneConfig.turnOnly.arrowKinds(isInner: false), ['right']);
      // No left anywhere.
      expect(LaneConfig.throughRight.commandable(),
          {Maneuver.straight, Maneuver.right});
      // Inner left+through, outer right-only.
      expect(LaneConfig.leftThroughAndRight.arrowKinds(isInner: true),
          ['left', 'up']);
      expect(
          LaneConfig.leftThroughAndRight.arrowKinds(isInner: false), ['right']);
    });
  });
}
