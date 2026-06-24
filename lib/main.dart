import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'pages/admin_dashboard_page.dart';
import 'pages/landing_page.dart';
import 'pages/live_video_room_page.dart';
import 'pages/student_dashboard_page.dart';
import 'pages/teacher_dashboard_page.dart';
import 'services/call_manager.dart';
import 'services/call_notification_service.dart';
import 'theme/app_theme.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await CallNotificationService.showIncomingCallFromRemoteMessage(message);
  } catch (_) {
    // Never allow an uncaught exception to kill the background isolate
    // before the incoming-call screen can be shown.
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    }
  } catch (e) {
    debugPrint("Firebase initialization failed: $e");
  }

  // Set status bar style for a clean look
  if (!kIsWeb) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
    );
  }

  runApp(const ScholarsApp());
}

/// Global navigator key so call-acceptance navigation works reliably
/// even when the widget tree is still initializing.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class ScholarsApp extends StatelessWidget {
  const ScholarsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scholars Academy',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      navigatorKey: navigatorKey,
      home: const _AuthGate(),
    );
  }
}

/// Checks persisted login state and routes accordingly.
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _isLoading = true;
  Widget? _homePage;
  bool _loginCheckDone = false;
  final Set<String> _openedLiveClassKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _checkLoginState();
    
    CallNotificationService.init();

    if (!kIsWeb) {
      CallManager.listenToCallEvents((extra) {
        unawaited(_openIncomingClass(extra));
      });

      FirebaseMessaging.onMessageOpenedApp.listen(_openIncomingClassFromMessage);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!kIsWeb) {
        _recoverAcceptedCall();
        _recoverNotificationTap();
      }
    });
  }

  Future<void> _checkLoginState() async {
    final prefs = await SharedPreferences.getInstance();
    final adminLoggedIn = prefs.getBool('admin_logged_in') ?? false;
    final teacherLoggedIn = prefs.getBool('is_teacher_logged_in') ?? false;
    final studentLoggedIn = prefs.getBool('is_student_logged_in') ?? false;

    if (adminLoggedIn) {
      if (mounted) {
        setState(() {
          _homePage = const AdminDashboardPage();
          _isLoading = false;
          _loginCheckDone = true;
        });
      }
      return;
    }

    if (teacherLoggedIn) {
      final key = prefs.getString('teacher_data');
      if (key != null) {
        try {
          final snapshot = await FirebaseDatabase.instance
              .ref()
              .child('teachers')
              .child(key)
              .get();
          if (snapshot.value != null) {
            final tr = Map<dynamic, dynamic>.from(snapshot.value as Map);
            tr['key'] = key;
            if (mounted) {
              setState(() {
                _homePage = TeacherDashboardPage(teacherData: tr);
                _isLoading = false;
                _loginCheckDone = true;
              });
            }
            return;
          }
        } catch (_) {}
      }
      // Cleanup if failed
      await prefs.remove('is_teacher_logged_in');
    }

    if (studentLoggedIn) {
      final key = prefs.getString('student_data');
      if (key != null) {
        try {
          final snapshot = await FirebaseDatabase.instance
              .ref()
              .child('students')
              .child(key)
              .get();
          if (snapshot.value != null) {
            final st = Map<dynamic, dynamic>.from(snapshot.value as Map);
            st['key'] = key;
            await CallNotificationService.activateForStudent(key);
            if (mounted) {
              setState(() {
                _homePage = StudentDashboardPage(studentData: st);
                _isLoading = false;
                _loginCheckDone = true;
              });
            }
            if (kIsWeb) {
              final classId = Uri.base.queryParameters['classId'];
              final topic = Uri.base.queryParameters['topic'] ?? 'Live Class';
              if (classId != null && classId.isNotEmpty) {
                unawaited(_openIncomingClass(<String, dynamic>{
                  'classId': classId,
                  'topic': topic,
                  'startedAt': DateTime.now().millisecondsSinceEpoch.toString(),
                }));
              }
            }
            return;
          }
        } catch (_) {}
      }
      // Cleanup if failed
      await prefs.remove('is_student_logged_in');
      await CallNotificationService.deactivateStudentSession();
    }

    if (mounted) {
      setState(() {
        _homePage = const LandingPage();
        _isLoading = false;
        _loginCheckDone = true;
      });
    }
  }

  Future<void> _recoverAcceptedCall() async {
    // Wait for login check to finish so the navigator is ready
    while (!_loginCheckDone) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
    }
    // Extra delay to let the navigator settle
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    final extra = await CallManager.takeAcceptedCallFromActiveCalls();
    await _openIncomingClass(extra);
  }

  Future<void> _recoverNotificationTap() async {
    while (!_loginCheckDone) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    try {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      _openIncomingClassFromMessage(message);
    } catch (e) {
      debugPrint('Initial notification recovery skipped: $e');
    }
  }

  void _openIncomingClassFromMessage(RemoteMessage? message) {
    if (message == null) return;

    final data = message.data;
    if (data['type'] != 'incoming_class_call') return;

    final classId = data['classId']?.toString();
    if (classId == null || classId.isEmpty) return;

    unawaited(
      _openIncomingClass(<String, dynamic>{
        'classId': classId,
        'topic': data['topic']?.toString() ?? 'Live Class',
        if (data['teacherName'] != null) 'teacherName': data['teacherName'],
        if (data['startedAt'] != null) 'startedAt': data['startedAt'],
      }),
    );
  }

  Future<void> _openIncomingClass(Map<String, dynamic>? extra) async {
    if (extra == null) return;

    final classId = extra['classId']?.toString();
    final topic = extra['topic']?.toString() ?? 'Live Class';
    if (classId == null || classId.isEmpty) return;

    final startedAt = extra['startedAt']?.toString();
    final liveKey = startedAt == null || startedAt.isEmpty
        ? classId
        : '$classId:$startedAt';
    if (!_openedLiveClassKeys.add(liveKey)) {
      return;
    }

    final studentIdentity = await _loadCurrentStudentIdentity();

    if (!mounted) {
      return;
    }

    // Use the global navigator key for reliable navigation
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    nav.push(
      MaterialPageRoute(
        builder: (_) => LiveVideoRoomPage(
          isTeacher: false,
          classId: classId,
          topic: topic,
          participantId: studentIdentity['id'],
          participantName: studentIdentity['name'],
        ),
      ),
    );
  }

  Future<Map<String, String?>> _loadCurrentStudentIdentity() async {
    String? studentId;
    String? studentName;

    try {
      final prefs = await SharedPreferences.getInstance();
      studentId = prefs.getString('student_data');

      if (studentId != null && studentId.isNotEmpty) {
        final snapshot = await FirebaseDatabase.instance
            .ref()
            .child('students')
            .child(studentId)
            .get();
        final rawValue = snapshot.value;
        if (rawValue is Map) {
          final student = Map<dynamic, dynamic>.from(rawValue);
          studentName = student['name']?.toString();
        }
      }
    } catch (_) {}

    return <String, String?>{'id': studentId, 'name': studentName};
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _homePage == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primaryNavy),
        ),
      );
    }

    return _homePage!;
  }
}
