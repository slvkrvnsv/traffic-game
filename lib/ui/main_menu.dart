import 'package:flutter/material.dart';

/// Main menu: Play + Test buttons.
class MainMenuScreen extends StatelessWidget {
  const MainMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo / title
              const Icon(Icons.directions_car_filled_rounded,
                  size: 80, color: Color(0xFFFFD600)),
              const SizedBox(height: 16),
              const Text(
                'TRAFFIC',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 8,
                ),
              ),
              const Text(
                'RULES',
                style: TextStyle(
                  color: Color(0xFFFFD600),
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 12,
                ),
              ),
              const SizedBox(height: 60),
              _MenuButton(
                label: 'PLAY',
                color: const Color(0xFF66BB6A),
                icon: Icons.play_arrow_rounded,
                onTap: () => Navigator.pushNamed(context, '/game'),
              ),
              const SizedBox(height: 20),
              _MenuButton(
                label: 'TEST',
                color: const Color(0xFF42A5F5),
                icon: Icons.science_rounded,
                onTap: () => Navigator.pushNamed(context, '/test'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.label,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 220,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color, width: 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
