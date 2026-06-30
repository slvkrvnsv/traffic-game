import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/core/constants.dart';
import 'package:traffic_game/feedback/driver_reaction_detector.dart';

/// The one sharp correctness boundary of the reaction feature: a forced hard
/// brake (cut-in / brake-check) must fire, while a merge that forces no braking
/// must not. The discriminator uses the *closing* speed (npc.speed − player.speed),
/// so a player who tucks in at the NPC's own pace can't fault however tight the
/// gap, and only a slower/braking player closing onto a tight gap crosses the
/// threshold.
void main() {
  group('DriverReactionDetector.isForcedHardBrake (closing speed)', () {
    test('matched speed never fires — even tucked in tight', () {
      // closing == 0: the player merged in at the NPC's pace. No brake is forced
      // at any gap, which is the whole point — a normal merge isn't a cut-off.
      for (final gap in [40.0, 70.0, 104.0, 200.0]) {
        expect(
          DriverReactionDetector.isForcedHardBrake(0.0, gap),
          isFalse,
          reason: 'gap=$gap at matched speed is a normal merge',
        );
      }
    });

    test('player pulling away (negative closing) never fires', () {
      expect(DriverReactionDetector.isForcedHardBrake(-50.0, 40.0), isFalse);
    });

    test('a safe merge a couple car-lengths ahead does not fire', () {
      // The reported false positive: merging ~2 car-bodies in front while only
      // modestly slower. 15 km/h of closing onto a 2-length gap is a gentle ease,
      // not a hard brake.
      final closing = kmhToUnits(15);
      expect(DriverReactionDetector.isForcedHardBrake(closing, 2 * kCarLength),
          isFalse);
      // "a little less" than two bodies is still fine.
      expect(DriverReactionDetector.isForcedHardBrake(closing, 90.0), isFalse);
    });

    test('a tight cut-in (fast closing, small gap) fires', () {
      // The player merged in tight AND much slower → 50 km/h of closing onto 70u.
      final closing = kmhToUnits(50);
      expect(DriverReactionDetector.isForcedHardBrake(closing, 70.0), isTrue);
    });

    test('a brake-check (player stops right in front) fires', () {
      // Player ends up inside the standing gap, NPC closing at full speed →
      // brakeDist clamps, a_req blows up.
      final closing = kmhToUnits(40);
      expect(DriverReactionDetector.isForcedHardBrake(closing, 20.0), isTrue);
    });

    test('same gap discriminates on closing speed', () {
      // One car-length ahead: harmless at matched speed, a real cut-off when the
      // player is much slower (large closing).
      expect(DriverReactionDetector.isForcedHardBrake(0.0, kCarLength), isFalse);
      expect(DriverReactionDetector.isForcedHardBrake(kmhToUnits(45), kCarLength),
          isTrue);
    });

    test('crawling traffic with a tiny gap does not fire on its own', () {
      // Very low closing, small gap: a_req stays bounded — handled here by the
      // closing magnitude, and in the detector additionally gated by kReactMinSpeed.
      expect(DriverReactionDetector.isForcedHardBrake(kmhToUnits(5), 40.0),
          isFalse);
    });
  });
}
