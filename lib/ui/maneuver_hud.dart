import 'dart:async';
import 'package:flutter/material.dart';
import '../core/game_bus.dart';
import '../core/maneuver.dart';

/// Top-centre exam instruction: shows the commanded maneuver for the tile the
/// player is on ("Turn left" etc.), hidden on tiles with no instruction.
/// Flashes a green check when the player passes a rule cleanly.
class ManeuverHud extends StatefulWidget {
  const ManeuverHud({super.key});

  @override
  State<ManeuverHud> createState() => _ManeuverHudState();
}

class _ManeuverHudState extends State<ManeuverHud> {
  static const _icons = {
    Maneuver.straight: Icons.straight_rounded,
    Maneuver.left: Icons.turn_left_rounded,
    Maneuver.right: Icons.turn_right_rounded,
  };

  Maneuver? _maneuver;
  bool _showPassed = false;

  late final StreamSubscription<ManeuverAnnouncedEvent> _maneuverSub;
  late final StreamSubscription<RulePassedEvent> _passedSub;
  Timer? _passedTimer;

  @override
  void initState() {
    super.initState();
    _maneuverSub = GameBus.instance.on<ManeuverAnnouncedEvent>().listen((e) {
      setState(() => _maneuver = e.maneuver);
    });
    _passedSub = GameBus.instance.on<RulePassedEvent>().listen((_) {
      setState(() => _showPassed = true);
      _passedTimer?.cancel();
      _passedTimer = Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _showPassed = false);
      });
    });
  }

  @override
  void dispose() {
    _maneuverSub.cancel();
    _passedSub.cancel();
    _passedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _maneuver != null || _showPassed;
    final icon = _showPassed
        ? Icons.check_circle_rounded
        : (_maneuver != null ? _icons[_maneuver] : Icons.straight_rounded);
    final label = _showPassed ? 'Well done!' : (_maneuver?.label ?? '');
    final accent =
        _showPassed ? const Color(0xFF4CAF50) : const Color(0xFF42A5F5);

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 250),
          child: Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xDD161B22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: accent, size: 28),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
