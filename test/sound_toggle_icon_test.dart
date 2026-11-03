import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera_app/widgets/sound_toggle_icon.dart';

/// The capture-sound switch is now a bare glyph in the top bar (no circular
/// background). These tests pin down its three visual states and that it never
/// silently swallows a tap.
void main() {
  Widget harness(Widget child) => MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: child),
        ),
      );

  testWidgets('off state shows the muted glyph, no filled background', (tester) async {
    await tester.pumpWidget(harness(SoundToggleIcon(enabled: false, onTap: () {})));

    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);

    // Bare glyph: the only decorated box in the tree must not be a filled
    // circle. (IconResponse draws no background of its own.)
    final containers = tester.widgetList<Container>(find.byType(Container));
    for (final c in containers) {
      final deco = c.decoration;
      if (deco is BoxDecoration) {
        expect(deco.shape, isNot(BoxShape.circle),
            reason: 'sound toggle must not paint a circular background');
      }
    }
  });

  testWidgets('on state shows the speaker glyph', (tester) async {
    await tester.pumpWidget(harness(SoundToggleIcon(enabled: true, onTap: () {})));

    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });

  testWidgets('busy state shows a spinner instead of the glyph', (tester) async {
    await tester.pumpWidget(harness(SoundToggleIcon(enabled: true, busy: true, onTap: () {})));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);
  });

  testWidgets('tap calls back when the state is known', (tester) async {
    var taps = 0;
    await tester.pumpWidget(harness(SoundToggleIcon(enabled: true, onTap: () => taps++)));

    await tester.tap(find.byIcon(Icons.volume_up));
    expect(taps, 1);
  });

  testWidgets('tap on unknown state explains instead of doing nothing', (tester) async {
    await tester.pumpWidget(harness(
      SoundToggleIcon(enabled: null, cameraConnected: true, onTap: () {}),
    ));

    await tester.tap(find.byIcon(Icons.volume_off));
    await tester.pump();

    expect(find.textContaining('no sound switch'), findsOneWidget);
  });
}
