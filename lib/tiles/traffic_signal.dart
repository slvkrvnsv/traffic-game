/// Phase shown to one approach of a traffic signal.
enum SignalPhase { green, yellow, red }

/// Drives a 4-way signalised intersection.
///
/// Opposing approaches share a phase: the North–South pair runs green → yellow
/// while East–West holds red, then an all-red clearance, then the two pairs
/// swap. So two *conflicting* approaches are never green at once, and there is
/// always an all-red gap between swaps — the safety invariant a signal must
/// guarantee. The state is a single accumulator: [tick] advances it, [phaseFor]
/// reads it, so the whole cycle is pure and unit-testable.
class TrafficSignalController {
  /// [seed] only offsets the START phase (so neighbouring lights aren't
  /// synchronised, and the player meets reds about as often as greens) — it
  /// never changes the timing. Deterministic for a given seed.
  TrafficSignalController({int seed = 0})
      : _t = _cycle * ((seed.abs() % 997) / 997.0);

  // Durations (seconds). Short and game-paced: a full cycle is ~22s, so an
  // approaching player meets a fresh phase change within a normal run-up.
  static const double greenSeconds = 7.0;
  static const double yellowSeconds = 2.5;
  static const double allRedSeconds = 1.5;

  /// One group's slot: green, then yellow, then red (the red includes the
  /// shared all-red clearance with the other group's matching slot).
  static const double _slot = greenSeconds + yellowSeconds + allRedSeconds;
  static const double _cycle = _slot * 2;

  double _t;

  /// Advance the cycle. Robust to a large [dt] (wraps cleanly).
  void tick(double dt) {
    _t += dt;
    if (_t >= _cycle) _t %= _cycle;
  }

  /// Phase for an approach group. The N–S group leads the cycle; the E–W group
  /// is offset by exactly half a cycle, so whenever one group is in its
  /// green/yellow slot the other is necessarily red.
  SignalPhase phaseFor({required bool northSouth}) {
    final local = northSouth ? _t : (_t + _slot) % _cycle;
    if (local < greenSeconds) return SignalPhase.green;
    if (local < greenSeconds + yellowSeconds) return SignalPhase.yellow;
    return SignalPhase.red;
  }
}
