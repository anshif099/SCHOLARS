import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../components/login_option_card.dart';
import '../services/call_notification_service.dart';
import '../theme/app_theme.dart';
import 'admin_dashboard_page.dart';
import 'student_dashboard_page.dart';
import 'teacher_dashboard_page.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;

  late AnimationController _titleController;
  late Animation<double> _titleFade;
  late Animation<Offset> _titleSlide;

  String _appVersion = '';

  final _loginIdController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isEmailMode = false;
  bool _obscurePassword = true;
  bool _isLoading = false;

  // ── Hardcoded admin credentials ──
  static const String _adminEmail = 'admin@scholars.com';
  static const String _adminPassword = 'admin123';
  static const String _reviewerEmail = 'reviewer@yourdomain.com';
  static const String _reviewerPassword = 'Review@123';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();

    // Logo entrance animation
    _logoController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _logoScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOut),
    );

    // Title entrance animation
    _titleController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _titleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _titleController, curve: Curves.easeOut),
    );
    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _titleController, curve: Curves.easeOutCubic),
    );

    // Start animations in sequence
    _logoController.forward().then((_) {
      _titleController.forward();
    });

    _loginIdController.addListener(() {
      final text = _loginIdController.text.trim();
      final isEmail = text.contains('@');
      if (isEmail != _isEmailMode) {
        setState(() {
          _isEmailMode = isEmail;
        });
      }
    });
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = 'v${info.version}+${info.buildNumber}';
      });
    }
  }

  @override
  void dispose() {
    _logoController.dispose();
    _titleController.dispose();
    _loginIdController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.accentRed,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  String _normalizeLoginId(String value) {
    return value
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2212]'), '-')
        .replaceAll(RegExp(r'\s+'), '');
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

  Future<Map<dynamic, dynamic>?> _findTeacherByClassId(String classId) async {
    final snapshot = await FirebaseDatabase.instance
        .ref()
        .child('teachers')
        .get()
        .timeout(const Duration(seconds: 15));
    if (snapshot.value == null) return null;
    final map = Map<dynamic, dynamic>.from(snapshot.value as Map);
    for (var entry in map.entries) {
      if (entry.value is! Map) continue;
      final t = Map<dynamic, dynamic>.from(entry.value as Map);
      final tcId = t['class_id']?.toString().trim().toUpperCase();
      if (tcId == classId.trim().toUpperCase()) {
        return {'key': entry.key, ...t};
      }
    }
    return null;
  }

  Future<bool> _activateNotifications(String studentKey) async {
    if (kIsWeb) return false;
    try {
      return await CallNotificationService.activateForStudent(studentKey);
    } catch (e) {
      debugPrint('Student notification setup skipped: $e');
      return CallNotificationService.hasSavedToken(studentKey);
    }
  }

  void _handleLogin() async {
    final input = _loginIdController.text.trim();
    if (input.isEmpty) {
      _showError('Please enter your ID or Email.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (input.contains('@')) {
        // Admin Login
        final password = _passwordController.text.trim();
        if (password.isEmpty) {
          _showError('Please enter your password.');
          setState(() => _isLoading = false);
          return;
        }

        // Simulate delay like in AdminLoginPage
        await Future.delayed(const Duration(milliseconds: 800));

        final isAdmin = input.toLowerCase() == _adminEmail.toLowerCase() && password == _adminPassword;
        final isReviewer = input.toLowerCase() == _reviewerEmail.toLowerCase() && password == _reviewerPassword;

        if (isAdmin || isReviewer) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('admin_logged_in', true);
          await prefs.setString('admin_email', input);

          if (!mounted) return;
          setState(() => _isLoading = false);

          Navigator.of(context).pushAndRemoveUntil(
            PageRouteBuilder(
              pageBuilder: (_, _, _) => const AdminDashboardPage(),
              transitionsBuilder: (_, animation, _, child) {
                return FadeTransition(opacity: animation, child: child);
              },
              transitionDuration: const Duration(milliseconds: 400),
            ),
            (_) => false,
          );
        } else {
          _showError('Invalid admin email or password.');
          setState(() => _isLoading = false);
        }
      } else {
        // Teacher or Student Login
        final normalized = _normalizeLoginId(input);
        
        if (normalized.startsWith('CLS')) {
          // Attempt Teacher Login
          final teacherData = await _findTeacherByClassId(normalized);
          if (teacherData != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('is_teacher_logged_in', true);
            await prefs.setString('teacher_data', teacherData['key']);

            if (!mounted) return;
            setState(() => _isLoading = false);

            Navigator.of(context).pushAndRemoveUntil(
              PageRouteBuilder(
                pageBuilder: (_, _, _) => TeacherDashboardPage(teacherData: teacherData),
                transitionsBuilder: (_, animation, _, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
                transitionDuration: const Duration(milliseconds: 400),
              ),
              (_) => false,
            );
            return;
          }
        }
        
        // Try Student Login
        final studentData = await _findStudentByLoginId(normalized);
        if (studentData != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('is_student_logged_in', true);
          await prefs.setString('student_data', studentData['key']);
          
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
            (_) => false,
          );
          return;
        }

        // If not found as student and doesn't start with CLS but might be a teacher without prefix:
        if (!normalized.startsWith('CLS')) {
          final teacherData = await _findTeacherByClassId(normalized);
          if (teacherData != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('is_teacher_logged_in', true);
            await prefs.setString('teacher_data', teacherData['key']);

            if (!mounted) return;
            setState(() => _isLoading = false);

            Navigator.of(context).pushAndRemoveUntil(
              PageRouteBuilder(
                pageBuilder: (_, _, _) => TeacherDashboardPage(teacherData: teacherData),
                transitionsBuilder: (_, animation, _, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
                transitionDuration: const Duration(milliseconds: 400),
              ),
              (_) => false,
            );
            return;
          }
        }

        _showError('Invalid ID. Please check and try again.');
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Login failed: $e');
      _showError('An error occurred during login. Please try again.');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      body: Stack(
        children: [
          // Background decorative dots
          const Positioned.fill(child: FloatingDots()),

          // Subtle top gradient accent
          Positioned(
            top: -100,
            left: -50,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.primaryNavy.withValues(alpha: 0.04),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Subtle bottom-right gradient accent
          Positioned(
            bottom: -80,
            right: -60,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.accentRed.withValues(alpha: 0.04),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Main content
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      SizedBox(height: screenHeight * 0.06),

                      // ── Logo ──
                      ScaleTransition(
                        scale: _logoScale,
                        child: FadeTransition(
                          opacity: _logoFade,
                          child: Container(
                            width: 110,
                            height: 110,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(28),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primaryNavy
                                      .withValues(alpha: 0.12),
                                  blurRadius: 30,
                                  offset: const Offset(0, 10),
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(28),
                              child: Image.asset(
                                'assets/logo.png',
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // ── App Name ──
                      SlideTransition(
                        position: _titleSlide,
                        child: FadeTransition(
                          opacity: _titleFade,
                          child: Column(
                            children: [
                              Text(
                                'Scholars Academy',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineLarge
                                    ?.copyWith(
                                      fontSize: 26,
                                      height: 1.2,
                                    ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Enter your ID or Email to continue',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      fontSize: 15,
                                      color: AppColors.textLight,
                                    ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),

                      SizedBox(height: screenHeight * 0.04),

                      // ── Universal Login Form ──
                      Form(
                        key: _formKey,
                        child: Container(
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
                                'Login ID or Email',
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
                                textInputAction: _isEmailMode ? TextInputAction.next : TextInputAction.done,
                                onFieldSubmitted: (_) {
                                  if (!_isEmailMode) {
                                    _handleLogin();
                                  }
                                },
                                decoration: InputDecoration(
                                  hintText: 'e.g. STD-12345 or admin@scholars.com',
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
                              
                              // Dynamic Password Field
                              ClipRect(
                                child: AnimatedSize(
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut,
                                  child: AnimatedOpacity(
                                    duration: const Duration(milliseconds: 300),
                                    opacity: _isEmailMode ? 1.0 : 0.0,
                                    child: _isEmailMode
                                        ? Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              const SizedBox(height: 20),
                                              Text(
                                                'Password',
                                                style: GoogleFonts.poppins(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                  color: AppColors.primaryNavy,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              TextFormField(
                                                controller: _passwordController,
                                                obscureText: _obscurePassword,
                                                style: GoogleFonts.poppins(fontSize: 15),
                                                textInputAction: TextInputAction.done,
                                                onFieldSubmitted: (_) => _handleLogin(),
                                                decoration: InputDecoration(
                                                  hintText: '••••••••',
                                                  hintStyle: GoogleFonts.poppins(
                                                    color: AppColors.textLight,
                                                  ),
                                                  prefixIcon: Icon(
                                                    Icons.lock_outline_rounded,
                                                    color: AppColors.primaryNavy.withValues(
                                                      alpha: 0.6,
                                                    ),
                                                  ),
                                                  suffixIcon: IconButton(
                                                    icon: Icon(
                                                      _obscurePassword
                                                          ? Icons.visibility_off_outlined
                                                          : Icons.visibility_outlined,
                                                      color: AppColors.textLight,
                                                    ),
                                                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
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
                                            ],
                                          )
                                        : const SizedBox.shrink(),
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
                      ),

                      SizedBox(height: screenHeight * 0.04),

                      // ── Footer ──
                      Text(
                        'Powered by Scholars Academy',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.textLight.withValues(alpha: 0.6),
                          fontWeight: FontWeight.w400,
                        ),
                      ),

                      const SizedBox(height: 4),

                      Text(
                        _appVersion,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textLight.withValues(alpha: 0.4),
                        ),
                      ),

                      const SizedBox(height: 24),
                    ],
                  ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
