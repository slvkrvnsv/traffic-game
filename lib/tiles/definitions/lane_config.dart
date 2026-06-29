import '../../core/maneuver.dart';

/// Which maneuvers each lane of the 2-lane light intersection is FOR — the lane
/// rule the player is graded against and the arrows/placards advertise. The
/// single source of truth the renderer, the player branches, and the grader all
/// read, so a new layout is graded, not just painted.
///
/// The fixed branch geometry is the hard ceiling: a LEFT exists only off the
/// inner spine, a RIGHT only off the outer (straight is just staying on the
/// spine). So a config can only RESTRICT within `inner ⊆ {left, straight}`,
/// `outer ⊆ {straight, right}`; anything else has no spline to drive and is
/// rejected at construction (fail loudly, not a silent missing branch).
class LaneConfig {
  LaneConfig({required this.inner, required this.outer}) {
    if (inner.isEmpty || outer.isEmpty) {
      throw ArgumentError('LaneConfig: each lane needs at least one maneuver');
    }
    if (!inner.every(_innerDrivable.contains)) {
      throw ArgumentError('LaneConfig inner $inner exceeds drivable $_innerDrivable '
          '(left lives only on the inner spine)');
    }
    if (!outer.every(_outerDrivable.contains)) {
      throw ArgumentError('LaneConfig outer $outer exceeds drivable $_outerDrivable '
          '(right lives only on the outer spine)');
    }
  }

  /// Maneuvers the inner (centre-side) lane is for.
  final Set<Maneuver> inner;

  /// Maneuvers the outer (curb) lane is for.
  final Set<Maneuver> outer;

  static const Set<Maneuver> _innerDrivable = {Maneuver.left, Maneuver.straight};
  static const Set<Maneuver> _outerDrivable = {Maneuver.straight, Maneuver.right};

  Set<Maneuver> forLane({required bool isInner}) => isInner ? inner : outer;

  /// Is [m] a legal move from the given lane?
  bool allows({required bool isInner, required Maneuver m}) =>
      forLane(isInner: isInner).contains(m);

  /// Every maneuver some lane permits — the pool a run's command is drawn from.
  Set<Maneuver> commandable() => {...inner, ...outer};

  /// Arrow / placard glyph kinds for a lane, in display order (left, up, right).
  /// Matches the `'left' | 'up' | 'right'` vocabulary the painted arrows and the
  /// overhead placards already draw.
  List<String> arrowKinds({required bool isInner}) {
    final s = forLane(isInner: isInner);
    return [
      if (s.contains(Maneuver.left)) 'left',
      if (s.contains(Maneuver.straight)) 'up',
      if (s.contains(Maneuver.right)) 'right',
    ];
  }

  /// The current layout (inner = left-only ◄, outer = through + right ▲►).
  static final LaneConfig l1 =
      LaneConfig(inner: {Maneuver.left}, outer: {Maneuver.straight, Maneuver.right});

  /// Split: inner straight-only ▲, outer right-only ►.
  static final LaneConfig straightRightSplit =
      LaneConfig(inner: {Maneuver.straight}, outer: {Maneuver.right});

  /// Shared-straight: inner left + straight ◄▲, outer straight + right ▲►.
  static final LaneConfig sharedStraight = LaneConfig(
      inner: {Maneuver.left, Maneuver.straight},
      outer: {Maneuver.straight, Maneuver.right});

  /// Turn-only lanes: inner left ◄, outer right ► (no through — both must turn,
  /// like a forced-turn junction).
  static final LaneConfig turnOnly =
      LaneConfig(inner: {Maneuver.left}, outer: {Maneuver.right});

  /// No left anywhere: inner straight ▲, outer straight + right ▲►.
  static final LaneConfig throughRight = LaneConfig(
      inner: {Maneuver.straight}, outer: {Maneuver.straight, Maneuver.right});

  /// Inner left + through ◄▲, outer right-only ►.
  static final LaneConfig leftThroughAndRight = LaneConfig(
      inner: {Maneuver.left, Maneuver.straight}, outer: {Maneuver.right});

  /// Pool a tile draws a random layout from when none is injected.
  static final List<LaneConfig> presets = [
    l1,
    straightRightSplit,
    sharedStraight,
    turnOnly,
    throughRight,
    leftThroughAndRight,
  ];
}
