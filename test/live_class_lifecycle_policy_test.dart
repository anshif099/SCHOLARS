import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/services/live_class_lifecycle_policy.dart';

void main() {
  group('LiveClassLifecyclePolicy', () {
    test('keeps the student in an active class', () {
      expect(
        LiveClassLifecyclePolicy.shouldCloseStudentRoom(
          firebaseConnected: true,
          classSnapshot: <String, dynamic>{'is_live': true},
        ),
        isFalse,
      );
    });

    test('does not close from stale snapshots while Android is offline', () {
      for (final snapshot in <Object?>[
        null,
        <String, dynamic>{},
        <String, dynamic>{'is_live': false},
      ]) {
        expect(
          LiveClassLifecyclePolicy.shouldCloseStudentRoom(
            firebaseConnected: false,
            classSnapshot: snapshot,
          ),
          isFalse,
        );
      }
    });

    test('closes after the connected server confirms the class ended', () {
      expect(
        LiveClassLifecyclePolicy.shouldCloseStudentRoom(
          firebaseConnected: true,
          classSnapshot: <String, dynamic>{'is_live': false},
        ),
        isTrue,
      );
      expect(
        LiveClassLifecyclePolicy.shouldCloseStudentRoom(
          firebaseConnected: true,
          classSnapshot: null,
        ),
        isTrue,
      );
    });
  });
}
