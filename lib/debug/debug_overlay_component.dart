import 'dart:ui' as ui;
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'debug_state.dart';

/// Screen-space Flame component that renders the debug info panel.
/// Add to `camera.viewport` so it stays fixed on screen regardless of camera.
class DebugOverlayComponent extends Component {
  static const _bg = Color(0xCC000000);
  static const _headerColor = Color(0xFFFFD600);
  static const _textColor = Color(0xFFE0E0E0);
  static const _dimColor = Color(0xFF9E9E9E);
  static const _warnColor = Color(0xFFEF5350);
  static const double _fontSize = 11.0;
  static const double _panelWidth = 340.0;
  static const double _pad = 8.0;

  @override
  void render(Canvas canvas) {
    final lines = _buildLines();
    if (lines.isEmpty) return;

    // Measure total height
    final totalH = lines.length * (_fontSize + 3) + _pad * 2;

    // Background
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(_pad, _pad, _panelWidth, totalH),
        const Radius.circular(6),
      ),
      Paint()..color = _bg,
    );

    // Text lines
    double y = _pad * 2;
    for (final line in lines) {
      _drawLine(canvas, line, _pad * 2, y);
      y += _fontSize + 3;
    }
  }

  void _drawLine(Canvas canvas, _Line line, double x, double y) {
    final pb = ui.ParagraphBuilder(
      ui.ParagraphStyle(fontSize: _fontSize, fontFamily: 'Courier New'),
    )
      ..pushStyle(ui.TextStyle(color: line.color))
      ..addText(line.text);
    final para = pb.build()
      ..layout(const ui.ParagraphConstraints(width: _panelWidth - 16));
    canvas.drawParagraph(para, Offset(x, y));
  }

  List<_Line> _buildLines() {
    final out = <_Line>[];

    // ── Tile ──
    out.add(_Line('── TILES (${DebugState.activeTileCount}) ──', _headerColor));
    for (final name in DebugState.activeTileNames) {
      out.add(_Line('  $name', _dimColor));
    }
    out.add(_Line(
      'Active: ${DebugState.tileType}  scenario: ${DebugState.scenarioType}',
      _textColor,
    ));

    // ── Player ──
    out.add(_Line('── PLAYER ──', _headerColor));
    final brakeFlag = DebugState.playerBraking ? ' [BRAKE]' : '';
    final kmh = (DebugState.playerSpeed * 0.3).toStringAsFixed(0).padLeft(3);
    out.add(_Line(
      '  $kmh km/h'
      '  t=${DebugState.playerT.toStringAsFixed(2)}'
      '  (${DebugState.playerX.toStringAsFixed(0)}, ${DebugState.playerY.toStringAsFixed(0)})'
      '$brakeFlag',
      DebugState.playerBraking ? _warnColor : _textColor,
    ));

    // ── NPCs ──
    out.add(_Line('── NPCs (${DebugState.npcs.length}) ──', _headerColor));
    for (final npc in DebugState.npcs) {
      final isYielding = npc.intersectionActive && !npc.hasRightOfWay;
      out.add(_Line('  $npc', isYielding ? _warnColor : _textColor));
    }

    // ── Collision ──
    out.add(_Line('── COLLISION ──', _headerColor));
    if (DebugState.playerColliding) {
      final lane = DebugState.npcCollisionLane >= 0
          ? 'NPC L${DebugState.npcCollisionLane}'
          : 'pedestrian';
      out.add(_Line('  ⚠ CRASH  with $lane', _warnColor));
    } else {
      final gap = DebugState.nearestNpcGap;
      final gapStr = gap.isInfinite ? '  ∞' : gap.toStringAsFixed(0).padLeft(5);
      final gapM = gap.isInfinite ? '' : '  (${(gap * 0.0833).toStringAsFixed(1)} m)';
      out.add(_Line('  nearest=$gapStr u$gapM', _textColor));
    }

    return out;
  }
}

class _Line {
  const _Line(this.text, this.color);
  final String text;
  final Color color;
}
