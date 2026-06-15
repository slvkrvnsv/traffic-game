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

/// Pedestrian render priority (cars use CarBase priority 5/10).
const int kPedestrianPriority = 2;

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
/// Self-centring steer (radians of nose angle) per world-unit off-centre. Small
/// → a shallow corrective angle → a gradual, realistic drift back to the lane
/// (never reaches [kMaxBodyYaw] within a lane, so no clamp saturation/bounce).
const double kReturnGain = 0.0035;
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
/// How far past an edge lane the car may lean (fraction of a lane) when there
/// is no further lane to commit to — gives a soft "nothing there" feel.
const double kLaneEdgePullFraction = 0.4;

// ---------------------------------------------------------------------------
// Indicator blink
// ---------------------------------------------------------------------------
const double kIndicatorBlinkPeriod = 0.5; // seconds per on/off cycle
const double kIndicatorSignalDistance = 150.0; // units before turn → start blinking

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------
const double kCameraLerpSpeed = 6.0;
const double kCameraForwardOffset = 160.0; // look-ahead distance in front of car
const double kCameraLookAheadLerpSpeed = 3.0; // how fast look-ahead heading eases through turns (lower = gentler swing)
const double kCameraZoom = 0.55;
