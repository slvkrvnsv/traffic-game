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
  double _dragDx = 0.0; // accumulated horizontal travel for the active drag

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

  void _onSwipeStart(DragStartDetails _) {
    _dragDx = 0.0;
    InputState.instance.setLaneSteer(0.0);
  }

  void _onSwipeUpdate(DragUpdateDetails d) {
    _dragDx += d.delta.dx;
    // Strip the deadzone so a slight flinch produces no movement at all.
    double eff = 0.0;
    if (_dragDx > kLaneSteerDeadzone) {
      eff = _dragDx - kLaneSteerDeadzone;
    } else if (_dragDx < -kLaneSteerDeadzone) {
      eff = _dragDx + kLaneSteerDeadzone;
    }
    InputState.instance.setLaneSteer(eff);
  }

  void _onSwipeEnd() => InputState.instance.endLaneSteer();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Swipe layer — fills the screen, sits behind the pedals.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onSwipeStart,
            onHorizontalDragUpdate: _onSwipeUpdate,
            onHorizontalDragEnd: (_) => _onSwipeEnd(),
            onHorizontalDragCancel: _onSwipeEnd,
            child: const SizedBox.expand(),
          ),
        ),

        // Pedals — bottom-right corner: brake (left) + gas (right).
        Positioned(
          right: 24,
          bottom: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _PedalButton(
                icon: Icons.drag_handle_rounded,
                color: const Color(0xFFEF4444),
                pressed: _brakeDown,
                onChanged: _setBrake,
                width: 140.0,
                height: 88.0,
              ),
              const SizedBox(width: 18),
              _PedalButton(
                icon: Icons.keyboard_double_arrow_up_rounded,
                color: const Color(0xFF22C55E),
                pressed: _gasDown,
                onChanged: _setGas,
                width: 88.0,
                height: 140.0,
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

