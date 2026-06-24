import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/live_video_room_page.dart';
import 'call_manager.dart';

/// Watches a student's class for live-class events and shows a full-screen
/// incoming-call notification (via [CallManager] / flutter_callkit_incoming).
///
/// **Primary path** – a real-time RTDB listener on
/// `live_classes/{classId}`.  This works immediately, without Cloud
/// Functions, and fires whether the app is in the foreground or kept
/// alive in the background by Android.
///
/// **Fallback path** – FCM data messages (requires a deployed Cloud
/// Function on the Blaze plan).  Kept so that enabling it later is a
/// one-line change.
class CallNotificationService {
  static const String _incomingClassCallType = 'incoming_class_call';
  static const String _lastShownLiveKeyPref = 'last_shown_live_call_key';

  static bool _isInitialized = false;
  static bool _foregroundMessageListenerAttached = false;
  static StreamSubscription<String>? _tokenRefreshSubscription;
  static StreamSubscription<DatabaseEvent>? _liveClassSubscription;
  static String? _activeStudentKey;

  // ---------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------

  /// Called once from [main.dart] at startup.
  static Future<void> init() async {
    try {
      await _ensureInitialized();
    } catch (e) {
      debugPrint('CallNotificationService init skipped: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    final studentLoggedIn = prefs.getBool('is_student_logged_in') ?? false;
    final studentKey = prefs.getString('student_data');
    if (!studentLoggedIn || studentKey == null || studentKey.isEmpty) {
      return;
    }

    try {
      await activateForStudent(studentKey);
    } catch (e) {
      debugPrint('CallNotificationService activation skipped: $e');
    }
  }

  /// Begin listening for live-class events for the given student.
  ///
  /// Returns true when Android/iOS notification permission is usable and the
  /// student's current FCM token was saved to the database.
  static Future<bool> activateForStudent(String studentKey) async {
    try {
      await _ensureInitialized();
    } catch (e) {
      debugPrint('CallNotificationService setup skipped: $e');
    }

    if (_activeStudentKey != null &&
        _activeStudentKey != studentKey &&
        _activeStudentKey!.isNotEmpty) {
      try {
        await _clearStudentToken(_activeStudentKey!);
      } catch (e) {
        debugPrint('Previous FCM token cleanup skipped: $e');
      }
    }

    _activeStudentKey = studentKey;

    var permissionReady = false;
    try {
      permissionReady = await _requestPermissions();
    } catch (e) {
      debugPrint('Notification permission setup skipped: $e');
    }

    var tokenSaved = false;
    try {
      tokenSaved = await _syncCurrentToken(studentKey);
    } catch (e) {
      debugPrint('FCM token sync skipped: $e');
    }

    // --- FCM token refresh (fallback for future Cloud Function) ---
    await _tokenRefreshSubscription?.cancel();
    try {
      _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
          .listen((token) {
            unawaited(
              _saveStudentToken(studentKey, token).catchError((Object e) {
                debugPrint('FCM token refresh save skipped: $e');
              }),
            );
          });
    } catch (e) {
      debugPrint('FCM token refresh listener skipped: $e');
    }

    // --- RTDB live-class listener (primary path) ---
    await _startLiveClassListener(studentKey);

    return permissionReady && tokenSaved;
  }

  static Future<bool> hasSavedToken(String studentKey) async {
    try {
      final tokenSnapshot = await FirebaseDatabase.instance
          .ref()
          .child('students')
          .child(studentKey)
          .child('fcm_token')
          .get()
          .timeout(const Duration(seconds: 8));
      final token = tokenSnapshot.value?.toString();
      return token != null && token.isNotEmpty;
    } catch (e) {
      debugPrint('FCM token status check skipped: $e');
      return false;
    }
  }

  /// Stop all listeners and clean up tokens.
  static Future<void> deactivateStudentSession() async {
    final studentKey = _activeStudentKey;
    _activeStudentKey = null;

    await _liveClassSubscription?.cancel();
    _liveClassSubscription = null;

    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;

    if (studentKey == null || studentKey.isEmpty) {
      return;
    }

    try {
      await _clearStudentToken(studentKey);
    } catch (e) {
      debugPrint('FCM token cleanup skipped: $e');
    }
  }

  /// Show the incoming call UI from an FCM data message.
  static Future<void> showIncomingCallFromRemoteMessage(
    RemoteMessage message,
  ) async {
    try {
      final callData = _extractCallData(message);
      if (callData == null) {
        return;
      }

      await _showCallIfNew(callData);
    } catch (_) {
      // Never let an unhandled exception kill the background isolate.
    }
  }

  // ---------------------------------------------------------------
  // RTDB live-class listener
  // ---------------------------------------------------------------

  static Future<void> _startLiveClassListener(String studentKey) async {
    await _liveClassSubscription?.cancel();
    _liveClassSubscription = null;

    // Look up the student's class_id from the database.
    try {
      final studentSnap = await FirebaseDatabase.instance
          .ref()
          .child('students')
          .child(studentKey)
          .get();

      if (!studentSnap.exists || studentSnap.value == null) {
        return;
      }

      final studentMap = Map<String, dynamic>.from(studentSnap.value as Map);
      final classId = studentMap['class_id']?.toString();
      if (classId == null || classId.isEmpty) {
        return;
      }

      final liveRef = FirebaseDatabase.instance
          .ref()
          .child('live_classes')
          .child(classId);

      _liveClassSubscription = liveRef.onValue.listen((event) {
        final rawValue = event.snapshot.value;
        if (rawValue == null || rawValue is! Map) {
          return;
        }

        final liveData = Map<String, dynamic>.from(rawValue);
        if (liveData['is_live'] != true) {
          return;
        }

        final callData = <String, dynamic>{
          'classId': classId,
          'topic': liveData['topic']?.toString() ?? 'Live Class',
          'teacherName': liveData['teacher_name']?.toString() ?? 'Teacher',
          'startedAt':
              liveData['started_at']?.toString() ??
              DateTime.now().millisecondsSinceEpoch.toString(),
        };

        unawaited(_showCallIfNew(callData));
      });
    } catch (_) {
      // Non-fatal – the FCM fallback path can still work.
    }
  }

  // ---------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------

  /// Deduplicates by `classId:startedAt` and shows the incoming call.
  static Future<void> _showCallIfNew(Map<String, dynamic> callData) async {
    // --- Deduplication (best-effort) ---
    try {
      final prefs = await SharedPreferences.getInstance();
      final liveKey = _buildLiveKey(callData);
      final lastShownLiveKey = prefs.getString(_lastShownLiveKeyPref);
      if (liveKey == lastShownLiveKey) {
        return;
      }
      await prefs.setString(_lastShownLiveKeyPref, liveKey);
    } catch (_) {
      // Proceed even if deduplication fails.
    }

    final teacherName = callData['teacherName']?.toString() ?? 'Teacher';
    final classId = callData['classId']!.toString();
    final topic = callData['topic']?.toString() ?? 'Live Class';
    final startedAt = callData['startedAt']?.toString();

    if (kIsWeb) {
      _showWebForegroundCallAlert(classId, topic, teacherName, startedAt);
      return;
    }

    await CallManager.showIncomingCall(
      name: 'Class Live: $teacherName',
      classId: classId,
      topic: topic,
      startedAt: startedAt,
    );
  }

  static void _showWebForegroundCallAlert(
    String classId,
    String topic,
    String teacherName,
    String? startedAt,
  ) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          elevation: 16,
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF2E2F6E).withValues(alpha: 0.15),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Calling Icon
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E2F6E).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.ring_volume_rounded,
                    size: 36,
                    color: Color(0xFF2E2F6E),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Incoming Class Call',
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Teacher $teacherName is inviting you to a live class.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    color: const Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 20),
                // Card for Class Topic
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'TOPIC',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF9CA3AF),
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        topic,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF2E2F6E),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          side: const BorderSide(color: Color(0xFFE5E7EB)),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(
                          'Decline',
                          style: GoogleFonts.poppins(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF6B7280),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E2F6E),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          Navigator.of(context).pop();
                          
                          // Navigate to live room
                          final prefs = await SharedPreferences.getInstance();
                          final key = prefs.getString('student_data');
                          
                          String? participantName;
                          if (key != null) {
                            try {
                              final snapshot = await FirebaseDatabase.instance
                                  .ref()
                                  .child('students')
                                  .child(key)
                                  .get();
                              if (snapshot.value is Map) {
                                final st = Map<dynamic, dynamic>.from(snapshot.value as Map);
                                participantName = st['name']?.toString();
                              }
                            } catch (_) {}
                          }

                          final nav = navigatorKey.currentState;
                          if (nav != null) {
                            unawaited(
                              nav.push(
                                MaterialPageRoute(
                                  builder: (_) => LiveVideoRoomPage(
                                    isTeacher: false,
                                    classId: classId,
                                    topic: topic,
                                    participantId: key,
                                    participantName: participantName,
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                        child: Text(
                          'Join Class',
                          style: GoogleFonts.poppins(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------
  // Initialization & FCM helpers
  // ---------------------------------------------------------------

  static Future<void> _ensureInitialized() async {
    if (_isInitialized) {
      return;
    }

    final messaging = FirebaseMessaging.instance;
    await messaging.setAutoInitEnabled(true);
    
    if (!kIsWeb) {
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    // FCM foreground listener (fallback path).
    if (!_foregroundMessageListenerAttached) {
      FirebaseMessaging.onMessage.listen((message) {
        unawaited(showIncomingCallFromRemoteMessage(message));
      });
      _foregroundMessageListenerAttached = true;
    }

    _isInitialized = true;
  }

  static Future<bool> _requestPermissions() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      announcement: false,
      provisional: false,
    );

    if (!kIsWeb) {
      try {
        await CallManager.prepareIncomingCallUi();
      } catch (e) {
        debugPrint('Incoming call UI permission setup skipped: $e');
      }
    }

    return _authorizationCanShowNotifications(settings.authorizationStatus);
  }

  static bool _authorizationCanShowNotifications(AuthorizationStatus status) {
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }

  static Future<bool> _syncCurrentToken(String studentKey) async {
    String? token;
    try {
      token = await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('FCM getToken failed: $e');
    }
    if (token == null || token.isEmpty) {
      return false;
    }

    await _saveStudentToken(studentKey, token);
    return true;
  }

  static Future<void> _saveStudentToken(String studentKey, String token) async {
    await FirebaseDatabase.instance
        .ref()
        .child('students')
        .child(studentKey)
        .update(<String, dynamic>{
          'fcm_token': token,
          'fcm_updated_at': ServerValue.timestamp,
        });
  }

  static Future<void> _clearStudentToken(String studentKey) async {
    await FirebaseDatabase.instance
        .ref()
        .child('students')
        .child(studentKey)
        .update(<String, dynamic>{
          'fcm_token': null,
          'fcm_updated_at': ServerValue.timestamp,
        });
  }

  static Map<String, dynamic>? _extractCallData(RemoteMessage message) {
    final data = message.data;
    if (data['type'] != _incomingClassCallType) {
      return null;
    }

    final classId = data['classId'];
    if (classId == null || classId.isEmpty) {
      return null;
    }

    return <String, dynamic>{
      'classId': classId,
      'topic': data['topic'] ?? 'Live Class',
      'teacherName': data['teacherName'] ?? 'Teacher',
      'startedAt':
          data['startedAt'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
    };
  }

  static String _buildLiveKey(Map<String, dynamic> callData) {
    final classId = callData['classId']!.toString();
    final startedAt = callData['startedAt']?.toString() ?? 'live';
    return '$classId:$startedAt';
  }
}
