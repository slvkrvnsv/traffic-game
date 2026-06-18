import 'dart:ui';

/// A reaction an NPC driver has to something the player did to them.
///
/// Domain-only: the kind plus how it should read (colour, on-screen lifetime).
/// The actual bubble drawing lives in [ReactionBubble]; detection lives in
/// [DriverReactionDetector]. Add new kinds here (e.g. tailgated, honkedAt) and
/// both the detector and the bubble extend naturally — this is the scalable
/// seam for player-error feedback across every scenario.
enum DriverReaction {
  /// The player cut in / merged so tightly the driver had to brake hard.
  cutOff,

  /// The player crossed an all-way stop out of turn — these drivers had the
  /// right of way and the player failed to yield to them.
  failedToYield;

  /// How long the bubble stays on screen (seconds).
  double get duration => switch (this) {
        DriverReaction.cutOff => 1.4,
        DriverReaction.failedToYield => 1.6,
      };

  /// Bubble colour — red for a fault the player should feel bad about.
  Color get color => switch (this) {
        DriverReaction.cutOff => const Color(0xFFE53935),
        DriverReaction.failedToYield => const Color(0xFFE53935),
      };
}
