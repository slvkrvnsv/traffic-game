import 'dart:ui';
import 'package:flame/components.dart';
import '../core/constants.dart';
import '../core/spline.dart';
import '../core/spline_follower.dart';

/// A pedestrian that walks a spline (a sidewalk route that may cross a road).
class Pedestrian extends PositionComponent with SplineFollower {
  Pedestrian({
    required Spline crossingPath,
    required this.walkSpeed,
    required this.color,
    required this.skinColor,
    required this.hairColor,
    Vector2? worldOffset,
    double worldAngle = 0.0,
  }) : super(
          size: Vector2(22, 22),
          anchor: Anchor.center,
          priority: kPedestrianPriority,
        ) {
    // Splines are authored tile-local; the pedestrian is a world child, so it
    // carries the owning tile's placement (like NPC cars do).
    assignSpline(crossingPath, worldOffset: worldOffset, worldAngle: worldAngle);
    // Keep to the right of the route centreline: opposite-direction walkers on a
    // shared centreline slide to opposite sides and pass without overlapping.
    lateralOffset = kPedLaneOffset;
    position.setFrom(splinePosition);
    angle = splineAngle;
  }

  final double walkSpeed;

  /// Shirt/body colour.
  final Color color;

  /// Skin tone for the head.
  final Color skinColor;

  /// Hair colour, or null for bald (head shows skin).
  final Color? hairColor;

  // Set each frame by TileManager: a car's bounding box is on the next step.
  // The pedestrian respects it — it holds rather than walking into the box.
  bool _blockedByPlayer = false;
  bool _blockedByNpc = false;
  // Pedestrian-vs-pedestrian avoidance. A ped NEVER stops for another ped (only
  // for cars / the player) — it leans aside and keeps moving, so nobody freezes
  // face-to-face or ghosts through. Kept apart from the car flags so the give-way
  // fault (which keys off [blockedByPlayer]) is never confused by a ped lean.
  //
  // [_avoidSign] is the COMMITTED lean direction (+1 right / −1 left) for the
  // current encounter: chosen once when a threat first appears and held until the
  // walkers have passed AND the lean has eased back, so the figure drifts apart
  // smoothly instead of bouncing as the instantaneous geometry flips mid-pass.
  // [_avoidSuggested] is the raw per-frame suggestion from TileManager (a signed
  // step when a converging walker is predicted within [kPedAvoidMiss], else 0).
  // [_avoidLinger] holds the lean out for a moment after the suggestion clears,
  // bridging the brief "alongside" instant when the other is neither ahead nor
  // yet passed — without it the lean would collapse mid-pass and clip the other.
  // [_threatened] (derived each frame in [update]) is what actually drives the
  // lean out, and its release the lean back.
  double _avoidSign = 0.0;
  double _avoidSuggested = 0.0;
  double _avoidLinger = 0.0;
  bool _threatened = false;
  // Timeout timer for the breakable NPC-car hold (a rare mutual stand-off). It
  // resets when the car clears. Holding for the PLAYER never times out — a ped
  // must never walk through you and trigger an unfair crash (see [update]).
  double _npcHoldTime = 0.0;

  // Set each frame by TileManager: the player's car body is inside this
  // pedestrian's personal-space bubble. Tracked so the startle "!" pops once per
  // intrusion (rising edge), independent of whether the car blocks the next step.
  bool _startledByPlayer = false;

  void setBlocked({required bool player, required bool npc}) {
    _blockedByPlayer = player;
    _blockedByNpc = npc;
  }

  /// Set each frame by TileManager from [TileManager.pedAvoidSideStep]: a signed
  /// suggested side-step (±[kPedSideStep]) when a converging walker is predicted
  /// in this ped's path, or 0 when clear. The encounter state it feeds (commit,
  /// linger, release) is resolved in [update], which has the frame delta.
  void setAvoidance(double suggested) => _avoidSuggested = suggested;

  /// Whether the player's car is currently inside this pedestrian's personal
  /// space. Carries the previous frame's value for the rising-edge startle cue.
  bool get startledByPlayer => _startledByPlayer;
  void setStartled(bool value) => _startledByPlayer = value;

  /// Whether the player's car is currently in this pedestrian's path, so the
  /// pedestrian is held for it. This is the ground truth for "the player forced
  /// this pedestrian to stop" — the real-world give-way fault keys off it (see
  /// `IntersectionTile`), instead of any reach/clearance geometry.
  bool get blockedByPlayer => _blockedByPlayer;

  bool get hasCrossed => hasReachedEnd;

  @override
  void update(double dt) {
    super.update(dt);
    // Only a car (or the player) can STOP a pedestrian — it must never walk
    // through a vehicle. Another pedestrian never stops it: it leans aside
    // instead (see [setAvoidance]), so two walkers slip past without freezing or
    // ghosting. The player hold never times out (no unfair crash); the NPC hold
    // breaks after kPedHoldTimeout to clear a rare mutual stand-off.
    _npcHoldTime = _blockedByNpc ? _npcHoldTime + dt : 0.0;
    final bool hold =
        _blockedByPlayer || (_blockedByNpc && _npcHoldTime < kPedHoldTimeout);
    // Resolve the avoidance encounter: a live suggestion commits a lean
    // direction (held for the whole pass) and re-arms the linger; once the
    // suggestion clears, the linger keeps the lean out across the brief alongside
    // instant before finally releasing and letting it ease back.
    if (_avoidSuggested != 0.0) {
      _threatened = true;
      _avoidLinger = kPedAvoidLinger;
      if (_avoidSign == 0.0) _avoidSign = _avoidSuggested > 0.0 ? 1.0 : -1.0;
    } else if (_avoidLinger > 0.0) {
      _avoidLinger -= dt;
      _threatened = true;
    } else {
      _threatened = false;
      if ((lateralOffset - kPedLaneOffset).abs() < 0.5) _avoidSign = 0.0;
    }
    // Ease the lateral offset toward the keep-right baseline, plus the committed
    // side-step while threatened, capped so the lean tracks at a calm drift
    // (never a sideways snap). Runs even while held for a car, so a stopped ped
    // can still lean clear of a passing walker.
    final target =
        kPedLaneOffset + (_threatened ? _avoidSign * kPedSideStep : 0.0);
    final maxLean = kPedSideStepRate * dt;
    lateralOffset += (target - lateralOffset).clamp(-maxLean, maxLean);
    if (!hold) advanceByDistance(walkSpeed * dt);
    position.setFrom(splinePosition);
    angle = splineAngle;
  }

  @override
  void render(Canvas canvas) {
    // Flame's render origin is the top-left corner; translate to the centre so
    // the figure sits on the pedestrian's real position (matches CarBase).
    canvas.translate(size.x / 2, size.y / 2);

    // GTA-classic top-down: looking straight down. Shoulders are a rounded body
    // (wider across travel than front-to-back); the head a centred circle on
    // top, hair covering all but a sliver of face at the front; a tiny nose
    // marks facing. Forward = local +x (the car convention).
    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, 1), width: 15, height: 18),
      Paint()..color = const Color(0x33000000),
    );
    // Shoulders (shirt) — long axis across the direction of travel (y).
    final body = Rect.fromCenter(center: Offset.zero, width: 12, height: 16);
    canvas.drawOval(body, Paint()..color = color);
    canvas.drawOval(
      body,
      Paint()
        ..color = const Color(0x55000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    // Head — skin circle (the face shows at the front).
    canvas.drawCircle(Offset.zero, 5.4, Paint()..color = skinColor);
    // Hair — a slightly smaller circle nudged toward the back (−x), leaving the
    // forehead/face as skin. Skipped when bald.
    if (hairColor != null) {
      canvas.drawCircle(
          const Offset(-1.4, 0), 4.8, Paint()..color = hairColor!);
    }
    // Nose / facing nub just ahead of the head (local +x).
    canvas.drawCircle(const Offset(5.0, 0), 1.8, Paint()..color = skinColor);
  }
}
