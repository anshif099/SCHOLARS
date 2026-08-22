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

    group('joinable live class', () {
      final now = DateTime.fromMillisecondsSinceEpoch(200000);

      Map<String, dynamic> liveClassWithTeacherLastSeen(int lastSeen) {
        return <String, dynamic>{
          'is_live': true,
          'participants': <String, dynamic>{
            'teacher-id': <String, dynamic>{
              'role': 'teacher',
              'last_seen': lastSeen,
            },
          },
        };
      }

      test('accepts a live class with a recent teacher heartbeat', () {
        expect(
          LiveClassLifecyclePolicy.isJoinableSnapshot(
            liveClassWithTeacherLastSeen(170000),
            now: now,
          ),
          isTrue,
        );
      });

      test('rejects a stale live flag left by an ended class', () {
        expect(
          LiveClassLifecyclePolicy.isJoinableSnapshot(
            liveClassWithTeacherLastSeen(79000),
            now: now,
          ),
          isFalse,
        );
      });

      test('rejects a live class without connected teacher presence', () {
        expect(
          LiveClassLifecyclePolicy.isJoinableSnapshot(<String, dynamic>{
            'is_live': true,
          }, now: now),
          isFalse,
        );
      });

      test('rejects a class explicitly marked as ended', () {
        expect(
          LiveClassLifecyclePolicy.isJoinableSnapshot(
            liveClassWithTeacherLastSeen(190000)..['is_live'] = false,
            now: now,
          ),
          isFalse,
        );
      });

      test('accepts numeric-string Firebase timestamps', () {
        final snapshot = liveClassWithTeacherLastSeen(0);
        final participants = snapshot['participants'] as Map<String, dynamic>;
        final teacher = participants['teacher-id'] as Map<String, dynamic>;
        teacher['last_seen'] = '190000';

        expect(
          LiveClassLifecyclePolicy.isJoinableSnapshot(snapshot, now: now),
          isTrue,
        );
      });
    });
  });
}
