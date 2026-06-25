/// World units: 1 unit = 1 logical pixel at base zoom.
/// Tile is a square of TILE_SIZE × TILE_SIZE units.
const double kTileSize = 1200.0;

/// Road lane width (there are 2 lanes per direction = 4 lanes total on a 2-way road).
const double kLaneWidth = 80.0;

/// Road total width (1 lane each direction).
const double kRoadWidth = kLaneWidth * 2;

/// Pavement width on each side of the road.
const double kPavementWidth = 40.0;

// ---------------------------------------------------------------------------
// Car dimensions (logical units)
// ---------------------------------------------------------------------------
const double kCarLength = 52.0;
const double kCarWidth = 28.0;
const double kWheelLength = 12.0;
const double kWheelWidth = 6.0;

// ---------------------------------------------------------------------------
// Speed scale — km/h is the design language
// ---------------------------------------------------------------------------
// Every speed in the game is authored in real km/h (50, 60, 120, …); the engine
// derives world units/sec from it. ONE constant, kSpeedToKmh, ties km/h to
// on-screen motion and is the only "feel" knob — smaller ⇒ the same km/h
// scrolls faster. So the realistic numbers and the on-screen feel are
// independent: retune the feel here without touching any posted speed.
const double kSpeedToKmh = 0.2; // units/sec × this = km/h   (1 km/h = 5 u/s)

/// World speed (units/sec) → km/h, for the speedometer and comparisons.
double unitsToKmh(double units) => units * kSpeedToKmh;

/// km/h (speed limits, expected speeds, thresholds) → world units/sec.
double kmhToUnits(double kmh) => kmh / kSpeedToKmh;

// ---------------------------------------------------------------------------
// Speeds — authored in km/h, converted to the units/sec the engine uses
// ---------------------------------------------------------------------------
const double kPlayerMaxSpeedKmh = 150.0; // highway top speed
const double kPlayerMaxSpeed = kPlayerMaxSpeedKmh / kSpeedToKmh; // 750 u/s
// Player acceleration is speed-dependent (see PlayerCar.accelerationAt): a
// regular hatchback — punchy off the line, tapering as speed climbs, so the
// last stretch toward top speed is a slog. This is the launch (standstill)
// figure; it fades toward kPlayerAccelFloor of itself near max speed.
const double kPlayerLaunchAccelKmhPerSec = 16.0; // strong start → 0–50 km/h in ~4 s
const double kPlayerLaunchAccel = kPlayerLaunchAccelKmhPerSec / kSpeedToKmh; // 80 u/s²
/// Fraction of launch acceleration still available at top speed, so the car
/// can actually reach max instead of asymptoting forever.
const double kPlayerAccelFloor = 0.12;
const double kPlayerBraking = 450.0;      // u/s² (~90 km/h per s) → 150–0 in ~1.7 s (emergency)
const double kPlayerRollingDrag = 37.5;   // u/s² natural coast-down
// NPCs accelerate at a constant rate — no power curve needed.
const double kNpcAccelKmhPerSec = 11.0;
const double kNpcAcceleration = kNpcAccelKmhPerSec / kSpeedToKmh; // 55 u/s²

// Default city traffic range; a per-tile expected/limit speed will override
// this later (see TileBase.speedLimitKmh).
const double kNpcMinSpeedKmh = 30.0;
const double kNpcMaxSpeedKmh = 60.0;
const double kNpcMinSpeed = kNpcMinSpeedKmh / kSpeedToKmh; // 150 u/s
const double kNpcMaxSpeed = kNpcMaxSpeedKmh / kSpeedToKmh; // 300 u/s
const double kNpcTurnSpeedKmh = 25.0; // max speed through a curve
const double kNpcTurnSpeed = kNpcTurnSpeedKmh / kSpeedToKmh; // 125 u/s
const double kNpcBrakeDecel = 225.0; // u/s² reliable NPC decel (stop lines + following)
/// How much LESS braking distance an NPC reserves for a car ahead than a
/// flat-out stopping calculation would (it assumes it can brake this many times
/// harder than [kNpcBrakeDecel] when judging a moving lead). Higher = they let
/// you get closer / brake later and softer when you appear in front; 1.0 =
/// reserve the full distance (twitchy). This is THE knob for "less sensitive
/// to a cut-in" without killing the reaction entirely.
const double kNpcFollowReactionScale = 1.5;

// Distances (not speeds) — independent of the speed scale.
const double kNpcSafeGapDistance = 90.0; // min gap to car ahead (bumper to bumper)
const double kNpcStandingGap = 34.0;     // bumper-to-bumper gap behind a stopped car
const double kStopLineSetback = 14.0;    // gap between car nose and the stop line when halted

// ---------------------------------------------------------------------------
// NPC culling
// ---------------------------------------------------------------------------
const double kNpcCullDistance = 2200.0; // units behind player → remove NPC
const int kNpcHardCap = 20; // max simultaneous NPCs across all tiles

// ---------------------------------------------------------------------------
// Rules / violations
// ---------------------------------------------------------------------------
// Road-blocking: the player is punished for sitting still on a clear road with
// no reason to wait (nothing ahead, no yield/stop required by the tile).
// Rational stops — yielding, queued behind a car, pedestrians — are exempt.
const double kRoadBlockGraceSeconds = 3.0; // irrational standstill before fail
const double kClearPathAheadDistance = 220.0; // forward scan for a real blocker
// Defined in km/h and converted, so they stay correct if kSpeedToKmh changes.
const double kYieldSpeedThresholdKmh = 13.5; // must crawl below this at a yield line
const double kYieldSpeedThreshold = kYieldSpeedThresholdKmh / kSpeedToKmh;
const double kStopSpeedThresholdKmh = 2.4; // effectively stopped (stop sign)
const double kStopSpeedThreshold = kStopSpeedThresholdKmh / kSpeedToKmh;

// ---------------------------------------------------------------------------
// Tile hand-off
// ---------------------------------------------------------------------------
/// When player reaches this fraction along the tile spline, next tile spawns.
const double kHandOffTriggerT = 0.75;

/// How many tiles to keep alive ahead of the player.
const int kTilesAhead = 2;

/// How long (seconds) a through-traffic NPC may wait frozen at a dead leading
/// seam — no tile streamed in beyond it — before it despawns instead of
/// freezing forever. During normal driving the next tile streams in well under
/// this, so the car just continues; only when the player is stationary (no
/// hand-off, so no new tile) would cars otherwise pile up frozen and leak the
/// NPC budget. Off-screen by construction, so the despawn is invisible.
const double kSeamWaitTimeoutSeconds = 1.5;

/// Pedestrian render priority (cars use CarBase priority 5/10).
const int kPedestrianPriority = 2;

// ---------------------------------------------------------------------------
// Locale (urban / interurban) — see LocaleType
// ---------------------------------------------------------------------------
/// In free-drive the locale is rolled in stretches of this many consecutive
/// tiles so the world doesn't flip city↔countryside every tile; when a stretch
/// ends the next is re-rolled (it may repeat or flip). Test mode pins one locale.
const int kLocaleRunLength = 3;

// ---------------------------------------------------------------------------
// Pedestrians
// ---------------------------------------------------------------------------
/// Pedestrian walk-speed range (world units/sec). Authored to look like walking
/// next to traffic: at kSpeedToKmh this is ~3.6–6.8 km/h (a stroll to a brisk
/// walk), well under the cars' 30+ km/h. The spread gives each pedestrian a
/// visibly different pace.
const double kPedMinWalkSpeed = 18.0;
const double kPedMaxWalkSpeed = 34.0;
/// How far ahead (units, along the path) a vehicle watches for a pedestrian on a
/// zebra it will cross. Long enough to reach the EXIT crossing from the stop
/// line, so a turning car decides to hold at the line instead of committing to a
/// turn and then stopping mid-crossing.
const double kPedYieldScanDistance = 260.0;
/// Lateral tolerance (units) from a vehicle's heading axis within which a
/// pedestrian counts as "in my path". Kept under a lane width so a car only
/// yields to someone actually stepping into its lane (on the zebra) — NOT to a
/// pedestrian strolling the adjacent sidewalk, which sits ~60 units off the lane.
const double kPedYieldLateral = kLaneWidth * 0.6; // 48
/// Spawn cadence for crossing pedestrians on an urban intersection (seconds).
const double kCrossingPedInterval = 1.8;
/// Max simultaneous crossing pedestrians per intersection (they leave the corner
/// buildings, walk the sidewalks and cross the zebras — a busy city corner).
const int kCrossingPedMax = 10;
/// Pedestrians spawn no closer than this to the player. They emerge from
/// building doors (off the road, to the side), so this can be modest — a person
/// appearing in a doorway reads naturally, unlike a car popping into a lane.
const double kPedMinSpawnDist = 240.0;

/// A pedestrian respects a car's bounding box: it holds at the box rather than
/// walking into it. This is how far ahead (its next step) it probes for a car.
const double kPedStepProbe = 10.0;
/// Keep-right lateral offset (world units) every pedestrian rides off its
/// route's centreline. Two pedestrians meeting head-on on a shared centreline
/// each keep to their own right, so they slide to OPPOSITE sides (2× this = 24
/// apart) and pass with a clear gap — comfortably more than the ~16u figure
/// width, so shoulders don't visibly clip. Two of these lanes plus the figure
/// just fill the 40u pavement (a ped centred here spans to the curb edge), and
/// it sits well inside the ±26u zebra detection band (a crossing ped still reads
/// as on its zebra for the rules).
const double kPedLaneOffset = 12.0;
/// Avoidance side-step (world units) a walker leans to clear a CROSSING or
/// near-oncoming walker (a converging corner). A same-direction OVERTAKE doesn't
/// use this — the faster walker swaps to the open opposite lane (2×[kPedLaneOffset])
/// to pass, the way people actually overtake, then drifts back. Anticipatory:
/// triggered when a near pass is predicted within [kPedAvoidMiss]/[kPedAvoidHorizon].
const double kPedSideStep = 8.0;
/// Predicted closest-approach distance (world units) below which a pedestrian
/// treats another as a collision to avoid. Kept UNDER 2×[kPedLaneOffset] (=24)
/// so two walkers that will pass on their own keep-right lanes are recognised as
/// a clean pass and DON'T swerve — only a genuine near-miss (a same-lane catch-up
/// or a converging corner) trips it. Predicting the MISS, not mere proximity, is
/// what stops the nervous bouncing on ordinary passes.
const double kPedAvoidMiss = 16.0;
/// How far AHEAD IN TIME (seconds) a pedestrian looks for a converging walker.
/// Anticipation window: prediction uses both walkers' velocities so they begin
/// easing apart early and calmly, well before they would actually meet.
const double kPedAvoidHorizon = 1.6;
/// How fast (world units/sec) the side-step eases in and out. Calm (around the
/// walk speed) so the lean reads as a smooth drift, not a sharp bounce, while
/// still completing the wider overtake swing within the anticipation window.
const double kPedSideStepRate = 22.0;
/// How long (seconds) a pedestrian holds its committed lean after the predicted
/// threat clears. Bridges the brief instant when the other walker is alongside —
/// neither ahead (so no new suggestion) nor yet passed — so the lean doesn't
/// collapse and clip them just as they draw level.
const double kPedAvoidLinger = 0.5;
/// Radius of a pedestrian's personal-space bubble (~2× the ~12u footprint). When
/// the PLAYER's car body comes within this of a crossing pedestrian, the
/// pedestrian startles (pops the "!") — even if the car isn't on their exact
/// next step and even if it has already stopped a hair away. Tune up if cars
/// crowding pedestrians still read as "no reaction", down if a properly-stopped
/// car (nose ~30u back behind the line) wrongly startles a passing crosser.
const double kPedPersonalSpace = 20.0;
/// A pedestrian held by an NPC car this long (a rare mutual stand-off) gives up
/// and proceeds, so nothing freezes forever. (Holding for the PLAYER never times
/// out — a pedestrian must never walk through you and trigger an unfair crash.)
const double kPedHoldTimeout = 2.5;
/// Spawn cadence for ambient sidewalk walkers, by locale (seconds). Urban
/// streets are busy; interurban roads see the occasional rambler.
const double kAmbientPedIntervalUrban = 1.8;
const double kAmbientPedIntervalInterurban = 14.0;
/// Max simultaneous ambient walkers per tile, by locale.
const int kAmbientPedMaxUrban = 10;
const int kAmbientPedMaxInterurban = 2;

// ---------------------------------------------------------------------------
// Lane change (player) — kinematic steering
//
// The finger sets a steering intent that turns the car's *nose*. The car only
// moves sideways because it points off-axis while driving forward:
//   lateralSpeed = forwardSpeed · sin(headingAngle)
// So a lane change is a real arc (quick at speed, slow at low speed, impossible
// when stopped) and it can never crab sideways. Releasing steers the nose back
// with a damped auto-correction that decays smoothly onto the lane — no snap.
// ---------------------------------------------------------------------------
/// Finger travel (logical px, past the deadzone) that corresponds to full
/// steering lock. Smaller drags steer proportionally less.
const double kSteerInputRange = 110.0;
/// Finger travel (logical px) ignored at the start of a drag, so a slight
/// flinch never steers the car.
const double kLaneSteerDeadzone = 8.0;
/// Max nose angle (radians) away from the lane heading. Also the body yaw, so
/// the car always points where it's actually going.
const double kMaxBodyYaw = 0.42; // ~24°
/// Max rate (radians/sec) the nose can turn into a lane change — the speed of
/// the steering wheel on turn-in. Scaled by speed via [kHeadingFullSpeed].
const double kHeadingSlewRate = 4.0;
/// Max nose-turn rate when self-centring after release — deliberately lazier
/// than turn-in so aborting a lane change is a gentle, safe correction rather
/// than a snap back. Slower is always bounce-safe (a lagging nose under-steers,
/// only approaching the lane, never overshooting).
const double kReturnSlewRate = 1.8;
/// Speed for full steering response; below it the nose turns proportionally
/// slower, so low-speed lane changes are sluggish and a stopped car cannot turn
/// at all. Authored in km/h, converted to units.
const double kHeadingFullSpeedKmh = 33.0;
const double kHeadingFullSpeed = kHeadingFullSpeedKmh / kSpeedToKmh; // 165 u/s
/// Self-centring steer (radians of nose angle) per world-unit off-centre. Big
/// enough that the car visibly *steers* back into the lane (nose turns, wheels
/// crank) rather than crabbing sideways with an almost-straight nose. Overshoot
/// is impossible regardless — the lateral step is monotonic-clamped toward the
/// lane (and the offset settles at 0 if it would cross) — so a steeper gain is
/// safe; it just makes the correction read as a real steering input.
const double kReturnGain = 0.008;
/// Effective wheelbase (world units) used to derive the front-wheel angle from
/// the car's yaw rate (bicycle model: δ ≈ atan(wheelbase · yawRate / speed)).
/// Larger → wheels turn more for a given yaw rate.
const double kSteerWheelBase = 22.0;
/// Speed floor (units/sec) for the wheel-angle denominator, so the wheels don't
/// snap to full lock at a crawl.
const double kWheelSpeedFloor = 120.0;
/// Fraction of a lane width the car must actually travel past before it commits
/// to (sticks to) the adjacent lane. Must be > 0.5: after a commit the offset
/// rebases by a full lane, so exactly 0.5 would land on the opposite threshold
/// and ping-pong. 0.6 gives a clear hysteresis band.
const double kLaneCommitFraction = 0.6;
/// Lean (world units) of the universal "intention" cue: a held drag with no lane
/// to merge into that way nudges the car this slightly toward the side it's
/// leaning — a hint of intention (e.g. the turn it will pick at the next fork
/// node), NOT a drift toward the centreline (the old full edge-pull, ~32u, looked
/// like crossing into the opposite lane). This is the edge-pull cap on EVERY tile
/// now, so the lean feels the same everywhere. A feel knob.
const double kIntentionLean = 8.0;
/// How far a turn branch may have diverged from the through-lane (world units,
/// perpendicular) and STILL be takeable by a lean. A turn is committed onto the
/// NEAREST point of its branch (like a merge), so the commit isn't a single
/// knife-edge point at the branch start — it's a ZONE spanning the branch's
/// lead-in plus the early arc, while the branch still hugs the lane closer than
/// this. That makes "steer the turn as you REACH the intersection" work (the
/// natural late lean) instead of forcing a precise hard lean across one invisible
/// point; the leftover offset at commit (≤ this) glides out via the self-centre.
/// Pinched: must clear the branch's offset at the box mouth (~11u) so a lean AT
/// the box still catches; small enough that the 2-lane near/far turns stay
/// distinct. A feel knob.
const double kTurnCommitReach = 16.0;
/// Minimum real separation (world units) between the current lane and an
/// adjacent one before a discrete lane-change *commit* is allowed. The car may
/// still lean toward a closer lane, but no commit (and its haptic) fires until
/// the lanes are genuinely apart. Without this, a lane that diverges/converges
/// to near-coincidence (a widen lane just opening, or a merge lane pinching out
/// at its end) commits on a hair of offset and ping-pongs as the perpendicular
/// sign flips with numerical noise.
const double kMinLaneCommitSeparation = kLaneWidth * 0.35; // 28
/// Separation (world units) at which lane steering itself switches on. Below it
/// the tile's two lanes are effectively one (a widen lane not yet opened, a
/// merge lane converged at its end), so steering is disabled and the car
/// gradually self-centres onto the single lane — the same ease as a steering-off
/// tile hand-off. Smaller than [kMinLaneCommitSeparation] so the player can
/// start drifting as soon as the lane opens, while the commit still waits for a
/// genuine lane-width.
const double kSteerEnableSeparation = kLaneWidth * 0.1; // 8 — engages early



// ---------------------------------------------------------------------------
// Driver reactions (player-error feedback)
// ---------------------------------------------------------------------------
// An NPC reacts (red bubble) when the player forces it to brake hard — e.g.
// cutting in on an overtake. The discriminator vs. ordinary following is the
// *required* deceleration on a rising edge, measured against the distance the
// NPC actually plans its braking over: a_req = v² / (2·brakeDist), where
// brakeDist = gap − kNpcStandingGap. Steady following holds the NPC at
// v = sqrt(2·kNpcBrakeDecel·brakeDist), so there a_req == kNpcBrakeDecel exactly
// — independent of speed and distance. a_req only exceeds kNpcBrakeDecel when
// the gap stepped down faster than the controller could react (a cut-in or
// brake-check), so the threshold is a multiplier ABOVE 1. Per-NPC cooldown keeps
// it to one bubble per incident.
/// Multiple of [kNpcBrakeDecel] the required decel must exceed to count as a
/// forced hard brake. Must be > 1 (steady following sits exactly at 1×); the
/// headroom also absorbs per-frame braking jitter.
const double kReactHardBrakeMultiplier = 1.3;
/// NPC must be moving at least this fast to react — skips stop-and-go, where a
/// tiny gap spikes a_req harmlessly.
const double kReactMinSpeedKmh = 12.0;
const double kReactMinSpeed = kReactMinSpeedKmh / kSpeedToKmh;
/// Quiet period (seconds) after an NPC reacts before it can react again.
const double kReactCooldownSeconds = 4.0;
/// Only react when the NPC is roughly on-screen — no feedback for cars the
/// player can't see. Sized to the visible radius (see [kCameraZoom]).
const double kReactMaxDistance = 760.0;
/// A cut-off is a *same-direction* (same-lane) interaction: only blame the
/// player when its heading is within this of the NPC's. A turning NPC or
/// cross-traffic, whose heading diverges past this, is braking for its own path
/// — not because the player cut in. ~40°.
const double kReactMaxHeadingDelta = 0.7;
/// A cut-off is a *fresh* intrusion — the player just moved into the NPC's
/// path. If the player has been ahead in that lane longer than this, the NPC is
/// merely catching up / following (e.g. it rolls up behind a player waiting at
/// a stop), which is the NPC's business, not the player's fault.
const double kReactCutInWindowSeconds = 1.2;

// ---------------------------------------------------------------------------
// Indicator blink
// ---------------------------------------------------------------------------
const double kIndicatorBlinkPeriod = 0.5; // seconds per on/off cycle
const double kIndicatorSignalDistance = 500.0; // units before turn → start blinking

// Manual-blinker self-cancel — the digital "steering wheel snaps the stalk off".
// The player arms the blinker by hand; once the car has driven THROUGH a bend in
// the signalled direction and the road straightens again, it clears itself. The
// trigger reads the heading change [kSignalCancelLookahead] units ahead on the
// current spline: a real intersection turn peaks at ~1.27 rad there, so the enter
// gate sits at ~55% of that (gentle road curves stay well under it) and the exit
// gate sits low (a straight reads ~0).
const double kSignalCancelLookahead = 100.0;
const double kSignalCancelEnterCurve = 0.70; // rad: "I'm in a turn this way"
const double kSignalCancelExitCurve = 0.15; // rad: "the road is straight again"

/// A committed fork branch counts as a TURN (graded for "turned without
/// signalling") when its overall heading change exceeds this — a real turn
/// is ~90° (~1.57 rad); a straight-through fork is ~0.
const double kTurnGradeMinAngle = 0.5; // rad
/// Headlight courtesy-flash on/off cycle (quicker than a turn signal) — an NPC
/// flashing a hesitating player at an all-way stop to wave them on.
const double kHeadlightFlashPeriod = 0.18;

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------
const double kCameraLerpSpeed = 6.0;
const double kCameraForwardOffset = 160.0; // look-ahead distance in front of car
const double kCameraLookAheadLerpSpeed = 3.0; // how fast look-ahead heading eases through turns (lower = gentler swing)
const double kCameraZoom = 0.55;
