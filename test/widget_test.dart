import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:camera_app/app.dart';
import 'package:camera_app/services/camera_protocol.dart';
import 'package:camera_app/services/filter_service.dart';
import 'package:camera_app/services/image_service.dart';
import 'package:camera_app/services/mock_camera_protocol.dart';

/// Smoke test: the app boots and the three tabs are on screen.
///
/// The previous version of this test pumped [CameraApp] with no providers at all,
/// so it failed with `ProviderNotFoundException` from the day providers were
/// introduced. It now supplies the same three providers as `main.dart`, using the
/// mock protocol so no network/hardware is involved.
void main() {
  testWidgets('app boots and shows the three tabs', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<FilterService>.value(value: FilterService()),
          ChangeNotifierProvider<ImageService>.value(value: ImageService()),
          Provider<CameraProtocol>.value(value: MockCameraProtocol()),
        ],
        child: const CameraApp(),
      ),
    );

    // initState kicks off the connection check; one frame is enough for the
    // bottom tabs to be laid out.
    await tester.pump();

    expect(find.text('CAMERA'), findsOneWidget);
    expect(find.text('EFFECTS'), findsOneWidget);
    expect(find.text('BORDERS'), findsOneWidget);

    // Dispose the tree so the connection/live-view timers are cancelled and the
    // test does not fail with "A Timer is still pending".
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
