import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/main.dart';

void main() {
  testWidgets('SmartScanner app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const SmartScannerApp());

    // Verify that the dashboard header contains 'SmartScanner'
    expect(find.text('SmartScanner'), findsOneWidget);

    // Verify that the camera scan button 'Pindai Dokumen' is visible
    expect(find.text('Pindai Dokumen'), findsOneWidget);
  });
}
