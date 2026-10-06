import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class FirebaseUploadAuthService {
  FirebaseUploadAuthService._();
  static Future<String?>? _signInTask;

  static Future<String?> ensureSignedIn() {
    final pending = _signInTask;
    if (pending != null) return pending;
    final task = _ensureSignedIn();
    _signInTask = task;
    return task.whenComplete(() {
      if (identical(_signInTask, task)) _signInTask = null;
    });
  }

  static Future<String?> _ensureSignedIn() async {
    final auth = FirebaseAuth.instance;
    final currentUser = auth.currentUser;
    if (currentUser != null) {
      return currentUser.uid;
    }

    try {
      final credential = await auth.signInAnonymously();
      return credential.user?.uid;
    } on FirebaseAuthException catch (error) {
      debugPrint(
        'Firebase anonymous auth failed: ${error.code} ${error.message ?? ''}',
      );
      return null;
    } catch (error) {
      debugPrint('Firebase anonymous auth failed: $error');
      return null;
    }
  }
}
