import 'package:flutter_test/flutter_test.dart';
import 'package:camera_app/app.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const CameraApp());

    // Verify bottom tabs are present
    expect(find.text('CAMERA'), findsOneWidget);
    expect(find.text('EFFECTS'), findsOneWidget);
  });
}
