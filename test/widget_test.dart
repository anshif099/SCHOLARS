import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scholars/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('Payment popup blocks startup and cannot be dismissed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ScholarsApp());
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Payment required'), findsOneWidget);
    expect(find.textContaining('Rs. 717.63'), findsOneWidget);
    expect(find.textContaining('Rs. 1,000'), findsOneWidget);
    expect(
      find.textContaining('Please contact your management.'),
      findsOneWidget,
    );
    expect(find.text('Login ID or Email'), findsNothing);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Login ID or Email'), findsNothing);
  });
}
