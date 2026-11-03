import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera_app/widgets/capture_controls.dart';

/// The capture bar once put the sound switch to the right of the shutter, in a
/// fixed 72pt slot that could not hold both it and the timer button - the button
/// was pushed off the screen edge on device. The sound switch now lives in the
/// top bar, so these tests only guard the shutter row itself.
void main() {
  Widget harness({double width = 320}) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: width,
            height: 80,
            child: CaptureControls(
              onShutter: () {},
              enabled: true,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('does not overflow at 320pt (smallest iPhone width)', (tester) async {
    await tester.pumpWidget(harness(width: 320));

    // An overflowing Row reports a FlutterError during layout/paint.
    expect(
      tester.takeException(),
      isNull,
      reason: 'CaptureControls must fit a 320pt wide screen without overflowing',
    );
  });

  testWidgets('shutter row keeps timer, thumbnail and shutter on one line', (tester) async {
    const width = 428.0;
    await tester.pumpWidget(harness(width: width));

    final bar = tester.getRect(find.byType(CaptureControls));
    final timer = tester.getCenter(find.byIcon(Icons.timer));

    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
    expect(timer.dx, greaterThan(bar.center.dx), reason: 'timer sits right of the shutter');
    expect(timer.dx, lessThan(bar.right));
  });
}
