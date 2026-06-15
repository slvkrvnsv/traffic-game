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
  cutOff;

  /// How long the bubble stays on screen (seconds).
  double get duration => switch (this) {
        DriverReaction.cutOff => 1.4,
      };

  /// Bubble colour — red for a fault the player should feel bad about.
  Color get color => switch (this) {
        DriverReaction.cutOff => const Color(0xFFE53935),
      };
}
