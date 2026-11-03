import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:camera_app/screens/gallery_screen.dart';
import 'package:camera_app/services/camera_protocol.dart';
import 'package:camera_app/services/image_service.dart';
import 'package:camera_app/services/mock_camera_protocol.dart';

/// Regression test for a debug affordance that leaked into release builds.
///
/// The gallery AppBar carried an "Export Logs" bug button with no gate at all, so
/// it shipped to customers. It is now behind `GalleryScreen.showDevTools`
/// (default: [kDevTools]), and this test pins both states.
void main() {
  Widget wrap({required bool showDevTools}) {
    return MultiProvider(
      providers: [
        Provider<CameraProtocol>.value(value: MockCameraProtocol()),
        ChangeNotifierProvider<ImageService>.value(value: ImageService()),
      ],
      child: MaterialApp(home: GalleryScreen(showDevTools: showDevTools)),
    );
  }

  testWidgets('release-style build (showDevTools: false) hides the bug button',
      (tester) async {
    await tester.pumpWidget(wrap(showDevTools: false));
    await tester.pump();

    expect(find.byIcon(Icons.bug_report_outlined), findsNothing,
        reason: 'the log-export button must never reach a store build');
    // The rest of the bar is still there.
    expect(find.text('Camera Photos'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('developer build (showDevTools: true) still has it', (tester) async {
    await tester.pumpWidget(wrap(showDevTools: true));
    await tester.pump();

    expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
