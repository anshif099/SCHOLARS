import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scholars/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PackageInfo.setMockInitialValues(
      appName: 'Scholars',
      packageName: 'com.example.scholars',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('App renders landing page', (WidgetTester tester) async {
    await tester.pumpWidget(const ScholarsApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1600));

    // Verify that the landing page renders with the app name
    expect(find.text('Scholars Academy'), findsOneWidget);

    // Verify the three login options are present
    expect(find.text('Admin Login'), findsOneWidget);
    expect(find.text('Teacher Login'), findsOneWidget);
    expect(find.text('Student Login'), findsOneWidget);
  });
}
