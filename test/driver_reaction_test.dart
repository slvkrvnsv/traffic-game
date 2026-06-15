import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/feedback/driver_reaction_detector.dart';

/// The one sharp correctness boundary of the reaction feature: a forced hard
/// brake (cut-in / brake-check) must fire, while ordinary steady following must
/// not. Steady following holds the NPC at v = sqrt(2·D·brakeDist), which makes
/// the required decel exactly D — so it sits below the >1× threshold by design.
void main() {
  group('DriverReactionDetector.isForcedHardBrake', () {
    /// Equilibrium following speed for a given bumper-to-bumper gap.
    double steadyFollowSpeed(double gap) =>
        math.sqrt(2 * kNpcBrakeDecel * (gap - kNpcStandingGap));

    test('steady following never fires (a_req == 1×, below threshold)', () {
      for (final gap in [60.0, 90.0, 173.0, 270.0]) {
        final v = steadyFollowSpeed(gap);
        expect(
          DriverReactionDetector.isForcedHardBrake(v, gap),
          isFalse,
          reason: 'gap=$gap v=${v.toStringAsFixed(1)} is a normal follow',
        );
      }
    });

    test('a tight cut-in (high speed, small gap) fires', () {
      // 50 km/h closing onto a 70-unit gap — the player merged in tight.
      final v = kmhToUnits(50);
      expect(DriverReactionDetector.isForcedHardBrake(v, 70.0), isTrue);
    });

    test('a brake-check (player stops right in front) fires', () {
      // Player ends up inside the standing gap → brakeDist clamps, a_req blows up.
      final v = kmhToUnits(40);
      expect(DriverReactionDetector.isForcedHardBrake(v, 20.0), isTrue);
    });

    test('crawling traffic with a tiny gap does not fire on its own', () {
      // Very low speed, small gap: a_req stays bounded — handled here by speed,
      // and in the detector additionally gated by kReactMinSpeed.
      expect(DriverReactionDetector.isForcedHardBrake(kmhToUnits(5), 40.0),
          isFalse);
    });
  });
}
