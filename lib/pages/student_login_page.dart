import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/call_notification_service.dart';
import '../theme/app_theme.dart';
import 'student_dashboard_page.dart';

class StudentLoginPage extends StatefulWidget {
  const StudentLoginPage({super.key});

  @override
  State<StudentLoginPage> createState() => _StudentLoginPageState();
}

class _StudentLoginPageState extends State<StudentLoginPage>
    with SingleTickerProviderStateMixin {
  final _loginIdController = TextEditingController();
  bool _isLoading = false;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
        );
    _animController.forward();
  }

  @override
  void dispose() {
    _loginIdController.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _handleLogin() async {
    final loginId = _normalizeLoginId(_loginIdController.text);
    if (loginId.isEmpty) {
      _showError('Please enter your Login ID.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final studentData = await _findStudentByLoginId(loginId);

      if (studentData != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('is_student_logged_in', true);
        await prefs.setString(
          'student_data',
          studentData['key'],
        ); // Storing reference key
        final notificationsReady = await _activateNotifications(
          studentData['key'].toString(),
        ).timeout(const Duration(seconds: 20), onTimeout: () => false);

        if (!mounted) return;
        setState(() => _isLoading = false);

        Navigator.of(context).pushAndRemoveUntil(
          PageRouteBuilder(
            pageBuilder: (_, _, _) => StudentDashboardPage(
              studentData: studentData,
              showNotificationWarning: !notificationsReady,
            ),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: const Duration(milliseconds: 400),
          ),
          (route) => false,
        );
      } else {
        _showError('Invalid Login ID. Please try again.');
        setState(() => _isLoading = false);
      }
    } on TimeoutException {
      _showError('Network timeout. Check internet and try again.');
      if (mounted) setState(() => _isLoading = false);
    } on FirebaseException catch (e) {
      final message = e.code == 'permission-denied'
          ? 'Database permission denied. Please update Realtime Database rules.'
          : 'Database error: ${e.message ?? e.code}';
      _showError(message);
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('Student login failed: $e');
      _showError('Unable to login. Check internet and try again.');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<Map<dynamic, dynamic>?> _findStudentByLoginId(String loginId) async {
    final studentsRef = FirebaseDatabase.instance.ref().child('students');
    final querySnapshot = await studentsRef
        .orderByChild('login_id')
        .equalTo(loginId)
        .limitToFirst(1)
        .get()
        .timeout(const Duration(seconds: 15));

    final exactMatch = _studentFromSnapshot(querySnapshot);
    if (exactMatch != null) {
      return exactMatch;
    }

    // Fallback for older records or phones that entered a unicode dash/spaces.
    final snapshot = await studentsRef.get().timeout(
      const Duration(seconds: 15),
    );
    final rawValue = snapshot.value;
    if (rawValue is! Map) {
      return null;
    }

    final students = Map<dynamic, dynamic>.from(rawValue);
    for (final entry in students.entries) {
      if (entry.value is! Map) {
        continue;
      }
      final student = Map<dynamic, dynamic>.from(entry.value as Map);
      if (_normalizeLoginId(student['login_id']?.toString() ?? '') == loginId) {
        return {'key': entry.key, ...student};
      }
    }

    return null;
  }

  Map<dynamic, dynamic>? _studentFromSnapshot(DataSnapshot snapshot) {
    final rawValue = snapshot.value;
    if (rawValue is! Map) {
      return null;
    }

    final students = Map<dynamic, dynamic>.from(rawValue);
    for (final entry in students.entries) {
      if (entry.value is Map) {
        return {
          'key': entry.key,
          ...Map<dynamic, dynamic>.from(entry.value as Map),
        };
      }
    }

    return null;
  }

  Future<bool> _activateNotifications(String studentKey) async {
    try {
      return await CallNotificationService.activateForStudent(studentKey);
    } catch (e) {
      debugPrint('Student notification setup skipped: $e');
      return CallNotificationService.hasSavedToken(studentKey);
    }
  }

  String _normalizeLoginId(String value) {
    return value
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2212]'), '-')
        .replaceAll(RegExp(r'\s+'), '');
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.accentRed,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.cardBackground,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.divider),
                        ),
                        child: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 18,
                          color: AppColors.primaryNavy,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 60),

                  // Icon
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: AppColors.primaryNavy.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person_rounded,
                      size: 40,
                      color: AppColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Text
                  Text(
                    'Student Login',
                    style: GoogleFonts.poppins(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter your Student Login ID to access your portal',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 15,
                      color: AppColors.textLight,
                    ),
                  ),
                  const SizedBox(height: 50),

                  // Input Box
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryNavy.withValues(alpha: 0.05),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Login ID',
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.primaryNavy,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _loginIdController,
                          style: GoogleFonts.poppins(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: 'e.g. STD-12345',
                            hintStyle: GoogleFonts.poppins(
                              color: AppColors.textLight,
                            ),
                            prefixIcon: Icon(
                              Icons.badge_outlined,
                              color: AppColors.primaryNavy.withValues(
                                alpha: 0.6,
                              ),
                            ),
                            filled: true,
                            fillColor: AppColors.background,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: AppColors.primaryNavy,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 30),
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _handleLogin,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryNavy,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              elevation: 0,
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2.5,
                                    ),
                                  )
                                : Text(
                                    'Login to Portal',
                                    style: GoogleFonts.poppins(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
