/// The maneuver the game commands the player to perform on a tile — like a
/// driving-exam instruction. The player never chooses a route; the tile's
/// player spline already follows the commanded maneuver, and the player's
/// job is to execute it without breaking the rules.
enum Maneuver { straight, left, right }

extension ManeuverLabel on Maneuver {
  String get label => switch (this) {
        Maneuver.straight => 'Go straight',
        Maneuver.left => 'Turn left',
        Maneuver.right => 'Turn right',
      };
}
