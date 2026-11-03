import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera_app/widgets/camera_preview.dart';

/// The trial entry is what lets an App Review tester (who has no ZIVIGo camera)
/// reach the editing features at all. If it silently disappears, the app looks
/// empty to every reviewer — so pin its visibility rules down in tests.
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('disconnected preview offers the trial entry', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(
      CameraPreview(onTryWithoutCamera: () => taps++),
    ));

    expect(find.text('Camera Disconnected'), findsOneWidget);
    expect(find.text('Try without a camera'), findsOneWidget);

    await tester.tap(find.text('Try without a camera'));
    expect(taps, 1, reason: 'the button must call back into the trial flow');
  });

  testWidgets('connected preview hides the trial entry', (tester) async {
    await tester.pumpWidget(wrap(
      const CameraPreview(isConnected: true, onTryWithoutCamera: _noop),
    ));

    expect(find.text('Try without a camera'), findsNothing);
  });

  testWidgets('no callback means no entry (e.g. still verifying)', (tester) async {
    await tester.pumpWidget(wrap(const CameraPreview()));

    expect(find.text('Camera Disconnected'), findsOneWidget);
    expect(find.text('Try without a camera'), findsNothing);
  });
}

void _noop() {}
