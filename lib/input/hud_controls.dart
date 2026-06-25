import 'package:flutter/material.dart';
import '../core/constants.dart';
import 'input_state.dart';

/// Flutter overlay: one-thumb driving controls.
///
///   • Gas / brake — two round buttons in the bottom-right corner.
///     Press and hold to accelerate or brake; release to coast (rolling drag).
///   • Lane change — drag horizontally anywhere else on the screen. The car
///     steers under your finger and eases toward the next lane; pull it past
///     the halfway point and it sticks to that lane (with a haptic click).
///     A slight flinch just nudges it and it settles back.
///
/// The buttons sit above the swipe layer and swallow their own touches, so a
/// lane-change drag never lands on a pedal and vice-versa.
class HudControls extends StatefulWidget {
  const HudControls({super.key});

  @override
  State<HudControls> createState() => _HudControlsState();
}

class _HudControlsState extends State<HudControls> {
  bool _gasDown = false;
  bool _brakeDown = false;

  /// The single pointer currently steering, and where it first touched. Tracked by
  /// raw pointer id (not a GestureDetector drag) so the finger-UP is ALWAYS
  /// reported: the horizontal-drag recognizer can lose its end event in the
  /// multi-touch gesture arena (a second finger on the pedals), which left the
  /// steer stuck "on" after the finger lifted — so a released wheel still turned at
  /// a fork. A Listener has no arena: pointer-up/cancel fire unconditionally.
  int? _steerPointer;
  double _steerStartX = 0.0;

  void _setGas(bool down) {
    setState(() => _gasDown = down);
    final input = InputState.instance;
    if (down) {
      input.setBrakeLevel(0.0);
      input.setGasLevel(1.0);
    } else {
      input.setGasLevel(0.0);
    }
  }

  void _setBrake(bool down) {
    setState(() => _brakeDown = down);
    final input = InputState.instance;
    if (down) {
      input.setGasLevel(0.0);
      input.setBrakeLevel(1.0);
    } else {
      input.setBrakeLevel(0.0);
    }
  }

  // Steering is a raw horizontal swipe tracked by pointer id. The pedals are
  // opaque Listeners on top, so they consume the gas/brake finger and only the
  // steering finger ever reaches this layer.
  void _onSteerDown(PointerDownEvent e) {
    if (_steerPointer != null) return; // already steering with another finger
    _steerPointer = e.pointer;
    _steerStartX = e.position.dx;
    InputState.instance.setLaneSteer(0.0);
  }

  void _onSteerMove(PointerMoveEvent e) {
    if (e.pointer != _steerPointer) return;
    final dx = e.position.dx - _steerStartX; // total displacement from touchdown
    // Strip the deadzone so a slight flinch produces no movement at all.
    double eff = 0.0;
    if (dx > kLaneSteerDeadzone) {
      eff = dx - kLaneSteerDeadzone;
    } else if (dx < -kLaneSteerDeadzone) {
      eff = dx + kLaneSteerDeadzone;
    }
    InputState.instance.setLaneSteer(eff);
  }

  // Finger up OR the gesture was cancelled → the wheel releases to centre. This is
  // the load-bearing fix: it MUST run on every lift so a released wheel never keeps
  // steering into a fork.
  void _onSteerEnd(PointerEvent e) {
    if (e.pointer != _steerPointer) return;
    _steerPointer = null;
    InputState.instance.endLaneSteer();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Swipe layer — fills the screen, sits behind the pedals. A raw Listener
        // (not a horizontal-drag GestureDetector) so the finger-up always fires.
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onSteerDown,
            onPointerMove: _onSteerMove,
            onPointerUp: _onSteerEnd,
            onPointerCancel: _onSteerEnd,
            child: const SizedBox.expand(),
          ),
        ),

        // Controls — bottom-right corner. Left column: the two blinkers (< >)
        // sit above the brake; the gas runs tall on the right, as deep as the
        // whole column.
        Positioned(
          right: 24,
          bottom: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Fixed-width column so the blinker row and brake stay 140 wide
              // (a stretch Column would balloon to the loose incoming width).
              SizedBox(
                width: 140,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Manual turn signals: tap to arm a side, tap it again (or
                    // the other side) to switch or clear. Reading straight from
                    // InputState keeps the lit state in sync through a restart's
                    // reset().
                    ListenableBuilder(
                      listenable: InputState.instance,
                      builder: (context, _) {
                        final signal = InputState.instance.turnSignal;
                        return Row(
                          children: [
                            Expanded(
                              child: _BlinkerButton(
                                icon: Icons.chevron_left_rounded,
                                active: signal < 0,
                                onTap: () =>
                                    InputState.instance.toggleSignal(-1),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _BlinkerButton(
                                icon: Icons.chevron_right_rounded,
                                active: signal > 0,
                                onTap: () =>
                                    InputState.instance.toggleSignal(1),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    _PedalButton(
                      icon: Icons.drag_handle_rounded,
                      color: const Color(0xFFEF4444),
                      pressed: _brakeDown,
                      onChanged: _setBrake,
                      width: 140.0,
                      height: 88.0,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              _PedalButton(
                icon: Icons.keyboard_double_arrow_up_rounded,
                color: const Color(0xFF22C55E),
                pressed: _gasDown,
                onChanged: _setGas,
                width: 88.0,
                height: 152.0,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A hold-to-act pedal button. Pass explicit [width]/[height] for rectangular
/// shapes; omit both for the default circle.
class _PedalButton extends StatelessWidget {
  const _PedalButton({
    required this.icon,
    required this.color,
    required this.pressed,
    required this.onChanged,
    this.width,
    this.height,
  });

  final IconData icon;
  final Color color;
  final bool pressed;
  final ValueChanged<bool> onChanged;
  final double? width;
  final double? height;

  static const double _size = 84.0;

  @override
  Widget build(BuildContext context) {
    final double w = width ?? _size;
    final double h = height ?? _size;
    final BorderRadiusGeometry borderRadius = (width != null || height != null)
        ? BorderRadius.circular(20)
        : BorderRadius.circular(_size / 2);

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => onChanged(true),
      onPointerUp: (_) => onChanged(false),
      onPointerCancel: (_) => onChanged(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          color: pressed ? color : color.withValues(alpha: 0.55),
          border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 3),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: pressed ? 0.6 : 0.25),
              blurRadius: pressed ? 18 : 8,
              spreadRadius: pressed ? 2 : 0,
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 40),
      ),
    );
  }
}

/// A tap-to-toggle turn-signal button. Amber and glowing while armed, dim when
/// off — the same amber as the indicator stars painted on the car. Opaque, so a
/// tap toggles the blinker rather than falling through to the steering layer.
class _BlinkerButton extends StatelessWidget {
  const _BlinkerButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  static const Color _amber = Color(0xFFFFC400);

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => onTap(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: active ? _amber : _amber.withValues(alpha: 0.18),
          border: Border.all(
            color: Colors.white.withValues(alpha: active ? 0.9 : 0.4),
            width: 3,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: _amber.withValues(alpha: 0.7),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ]
              : const [],
        ),
        child: Icon(
          icon,
          color: active ? Colors.black : Colors.white.withValues(alpha: 0.8),
          size: 34,
        ),
      ),
    );
  }
}

