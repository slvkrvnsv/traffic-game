import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traffic_game/input/hud_controls.dart';
import 'package:traffic_game/input/input_state.dart';

/// The driving HUD: the blinker buttons sit above the brake in a fixed-width
/// column, with the gas tall on the right. Guards the layout (a stretch column
/// would balloon the brake / overflow) and the tap-to-toggle blinker wiring.
void main() {
  setUp(InputState.instance.reset);
  tearDown(InputState.instance.reset);

  Future<void> pumpHud(WidgetTester tester) {
    return tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [HudControls()])),
      ),
    );
  }

  testWidgets('the control cluster lays out without overflow, brake stays 140×88',
      (tester) async {
    await pumpHud(tester);
    expect(tester.takeException(), isNull);

    final brake = tester.getSize(
      find.ancestor(
        of: find.byIcon(Icons.drag_handle_rounded),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(brake.width, 140);
    expect(brake.height, 88);
  });

  testWidgets('tapping a blinker arms it; tapping it again clears it',
      (tester) async {
    await pumpHud(tester);
    expect(InputState.instance.turnSignal, 0);

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump();
    expect(InputState.instance.turnSignal, -1);

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump();
    expect(InputState.instance.turnSignal, 0);
  });

  testWidgets('arming the other side switches sides (mutually exclusive)',
      (tester) async {
    await pumpHud(tester);

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pump();
    expect(InputState.instance.turnSignal, 1);
  });
}
