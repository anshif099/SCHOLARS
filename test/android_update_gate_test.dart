import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/components/android_update_gate.dart';
import 'package:scholars/services/android_update_service.dart';

void main() {
  testWidgets('blocks the app and opens Google Play when an update exists', (
    tester,
  ) async {
    var storeOpened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: AndroidUpdateGate(
          forceCheckForTesting: true,
          updateChecker: () async => const AndroidUpdateCheckResult(
            updateRequired: true,
            availableVersionCode: 25,
          ),
          storeLauncher: () async {
            storeOpened = true;
            return true;
          },
          child: const Text('APP HOME'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Update required'), findsOneWidget);
    expect(find.text('APP HOME'), findsNothing);

    await tester.tap(find.text('Update Now'));
    await tester.pump();

    expect(storeOpened, isTrue);
    expect(find.text('APP HOME'), findsNothing);
  });

  testWidgets('opens the app when Google Play reports no update', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidUpdateGate(
          forceCheckForTesting: true,
          updateChecker: () async =>
              const AndroidUpdateCheckResult(updateRequired: false),
          child: const Text('APP HOME'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('APP HOME'), findsOneWidget);
    expect(find.text('Update required'), findsNothing);
  });

  testWidgets('does not bypass the gate when the update check fails', (
    tester,
  ) async {
    var attempts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: AndroidUpdateGate(
          forceCheckForTesting: true,
          updateChecker: () async {
            attempts += 1;
            if (attempts == 1) {
              throw Exception('offline');
            }
            return const AndroidUpdateCheckResult(updateRequired: false);
          },
          child: const Text('APP HOME'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unable to check for updates'), findsOneWidget);
    expect(find.text('APP HOME'), findsNothing);

    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('APP HOME'), findsOneWidget);
  });
}
