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
// Speeds (units per second)
// ---------------------------------------------------------------------------
const double kPlayerMaxSpeed = 500.0;
const double kPlayerAcceleration = 100.0;  // units/s² when gas held  → 0–100 km/h in ~3.3 s, 0–150 in ~5 s
const double kPlayerBraking = 300.0;       // units/s² at full brake → 150–0 in ~1.7 s (emergency stop); light braking stays soft via the eased joystick curve
const double kPlayerRollingDrag = 25.0;    // units/s² natural decel  → coasts naturally
const double kNpcMinSpeed = 100.0;
const double kNpcMaxSpeed = 200.0;
const double kNpcSafeGapDistance = 90.0; // min gap to car ahead (bumper to bumper)
const double kNpcBrakeDecel = 150.0;      // u/s² reliable NPC decel (stop lines + following)
const double kNpcStandingGap = 34.0;      // bumper-to-bumper gap kept behind a stopped car
const double kNpcTurnSpeed = 85.0;        // max speed through a curve (~25 km/h)
const double kStopLineSetback = 14.0;     // gap between car nose and the stop line when halted

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
const double kYieldSpeedThreshold = 45.0; // must be below this (~13.5 km/h) crossing a yield line
const double kStopSpeedThreshold = 8.0; // effectively stopped (stop sign)

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
// Indicator blink
// ---------------------------------------------------------------------------
const double kIndicatorBlinkPeriod = 0.5; // seconds per on/off cycle
const double kIndicatorSignalDistance = 150.0; // units before turn → start blinking

// ---------------------------------------------------------------------------
// Speed conversion
// ---------------------------------------------------------------------------

/// Game units → km/h.
/// Derived from: kTileSize (1200 u) ≈ 100 m real-world city block.
/// 1 u/s × (100 m / 1200 u) × 3.6 = 0.3 km/h.
/// Player max 280 u/s → 84 km/h; NPC 100-200 u/s → 30-60 km/h.
const double kSpeedToKmh = 0.3;

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------
const double kCameraLerpSpeed = 6.0;
const double kCameraForwardOffset = 160.0; // look-ahead distance in front of car
const double kCameraLookAheadLerpSpeed = 3.0; // how fast look-ahead heading eases through turns (lower = gentler swing)
const double kCameraZoom = 0.55;
