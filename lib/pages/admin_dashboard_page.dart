import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';

import '../theme/app_theme.dart';
import 'landing_page.dart';
import 'teacher_registration_page.dart';
import 'teacher_dashboard_page.dart';
import 'student_registration_page.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  int _selectedIndex = 0;

  int _teachersCount = 0;
  int _studentsCount = 0;
  int _classesCount = 0;
  Map<dynamic, dynamic>? _teachersMap;
  Map<dynamic, dynamic>? _studentsMap;
  bool _isTeachersLoading = true;
  bool _isStudentsLoading = true;
  String _adminEmail = 'admin@scholars.com';
  final TextEditingController _classSearchController = TextEditingController();
  final TextEditingController _studentSearchController = TextEditingController();
  bool _isClassSearchVisible = false;
  String _classSearchQuery = '';
  String _studentSearchQuery = '';
  String? _selectedStudentClassId;

  late final DatabaseReference _teachersRef =
      FirebaseDatabase.instance.ref().child('teachers');
  late final DatabaseReference _studentsRef =
      FirebaseDatabase.instance.ref().child('students');
  late final Stream<DatabaseEvent> _teachersStream = _teachersRef.onValue.asBroadcastStream();
  late final Stream<DatabaseEvent> _studentsStream = _studentsRef.onValue.asBroadcastStream();

  StreamSubscription<DatabaseEvent>? _teachersSubscription;
  StreamSubscription<DatabaseEvent>? _studentsSubscription;

  final List<_SidebarItem> _sidebarItems = [
    _SidebarItem(
      icon: Icons.dashboard_rounded,
      label: 'Dashboard',
      isAvailable: true,
    ),
    _SidebarItem(
      icon: Icons.class_rounded,
      label: 'Classes',
      isAvailable: true,
    ),
    _SidebarItem(
      icon: Icons.person_rounded,
      label: 'Students',
      isAvailable: true,
    ),
    _SidebarItem(
      icon: Icons.settings_rounded,
      label: 'Settings',
      isAvailable: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _loadOverviewStats();
    _loadAdminEmail();
  }

  Future<void> _loadAdminEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString('admin_email');
    if (email != null && email.isNotEmpty) {
      setState(() {
        _adminEmail = email;
      });
    }
  }

  @override
  void dispose() {
    _teachersSubscription?.cancel();
    _studentsSubscription?.cancel();
    _classSearchController.dispose();
    _studentSearchController.dispose();
    super.dispose();
  }

  void _toggleClassSearch() {
    setState(() {
      _isClassSearchVisible = !_isClassSearchVisible;
      if (!_isClassSearchVisible) {
        _classSearchController.clear();
        _classSearchQuery = '';
      }
    });
  }

  bool _matchesClassSearch(Map<String, dynamic> teacher, String query) {
    if (query.isEmpty) return true;

    final searchableText = [
      teacher['course'],
      teacher['name'],
      teacher['class_id'],
      teacher['batch'],
    ].whereType<Object>().join(' ').toLowerCase();

    return searchableText.contains(query);
  }

  void _loginAsClass(Map<String, dynamic> teacherData) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => TeacherDashboardPage(
          teacherData: Map<dynamic, dynamic>.from(teacherData),
          showAdminBackButton: true,
        ),
        transitionsBuilder: (_, animation, _, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  Map<String, dynamic>? _teacherForStudent(
    Map<String, dynamic> student,
    Map<String, Map<String, dynamic>> teacherByKey,
    Map<String, Map<String, dynamic>> teacherByClassId,
  ) {
    final teacherKey = student['teacher_id']?.toString();
    final classId = student['class_id']?.toString();

    if (teacherKey != null && teacherByKey.containsKey(teacherKey)) {
      return teacherByKey[teacherKey];
    }

    if (classId != null && teacherByClassId.containsKey(classId)) {
      return teacherByClassId[classId];
    }

    return null;
  }

  String _classNameForStudent(
    Map<String, dynamic> student,
    Map<String, Map<String, dynamic>> teacherByKey,
    Map<String, Map<String, dynamic>> teacherByClassId,
  ) {
    final teacher = _teacherForStudent(student, teacherByKey, teacherByClassId);
    final course = teacher?['course']?.toString().trim();

    if (course != null && course.isNotEmpty) {
      return course;
    }

    final classId = student['class_id']?.toString().trim();
    return classId == null || classId.isEmpty ? 'Unassigned Class' : classId;
  }

  bool _matchesStudentSearch(
    Map<String, dynamic> student,
    String className,
    String query,
  ) {
    if (query.isEmpty) return true;

    final searchableText = [
      student['name'],
      student['login_id'],
      student['mobile'],
      student['teacher_name'],
      student['class_id'],
      student['batch'],
      className,
    ].whereType<Object>().join(' ').toLowerCase();

    return searchableText.contains(query);
  }

  List<_ClassFilterOption> _buildClassFilterOptions(
    Map<String, Map<String, dynamic>> teacherByClassId,
  ) {
    final options = teacherByClassId.entries.map((entry) {
      final course = entry.value['course']?.toString().trim();
      return _ClassFilterOption(
        classId: entry.key,
        className: course == null || course.isEmpty ? entry.key : course,
      );
    }).toList();

    options.sort((a, b) => a.className.compareTo(b.className));
    return options;
  }

  void _loadOverviewStats() {
    _teachersSubscription = _teachersStream.listen((event) {
      if (event.snapshot.value != null) {
        final map = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        final classIds = map.values
            .map((e) {
              if (e is Map) {
                return e['class_id'];
              }
              return null;
            })
            .where((id) => id != null)
            .toSet();
        if (mounted) {
          setState(() {
            _teachersMap = map;
            _teachersCount = map.length;
            _classesCount = classIds.length;
            _isTeachersLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _teachersMap = {};
            _teachersCount = 0;
            _classesCount = 0;
            _isTeachersLoading = false;
          });
        }
      }
    }, onError: (err) {
      debugPrint('Error loading teachers overview: $err');
      if (mounted) {
        setState(() {
          _isTeachersLoading = false;
        });
      }
    });

    _studentsSubscription = _studentsStream.listen((event) {
      if (event.snapshot.value != null) {
        final map = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        if (mounted) {
          setState(() {
            _studentsMap = map;
            _studentsCount = map.length;
            _isStudentsLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _studentsMap = {};
            _studentsCount = 0;
            _isStudentsLoading = false;
          });
        }
      }
    }, onError: (err) {
      debugPrint('Error loading students overview: $err');
      if (mounted) {
        setState(() {
          _isStudentsLoading = false;
        });
      }
    });
  }

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.info_outline_rounded,
                color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Text(
              '$feature — Coming soon!',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
            ),
          ],
        ),
        backgroundColor: AppColors.primaryNavy,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _handleLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Logout',
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w600,
            color: AppColors.primaryNavy,
          ),
        ),
        content: Text(
          'Are you sure you want to logout?',
          style: GoogleFonts.poppins(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(
                color: AppColors.textLight,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              // Clear persisted login state
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('admin_logged_in', false);
              await prefs.remove('admin_email');

              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              navigator.pushAndRemoveUntil(
                PageRouteBuilder(
                  pageBuilder: (_, _, _) => const LandingPage(),
                  transitionsBuilder: (_, animation, _, child) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                  transitionDuration: const Duration(milliseconds: 400),
                ),
                (_) => false,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentRed,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'Logout',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _showAdminProfile() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Avatar
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryNavy.withValues(alpha: 0.2),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.admin_panel_settings_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),

            const SizedBox(height: 16),

            Text(
              'Administrator',
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryNavy,
              ),
            ),

            const SizedBox(height: 4),

            Text(
              'Scholars Academy',
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: AppColors.textLight,
              ),
            ),

            const SizedBox(height: 24),

            // Detail rows
            _profileDetailRow(
              icon: Icons.email_outlined,
              label: 'Email',
              value: _adminEmail,
            ),
            const SizedBox(height: 12),
            _profileDetailRow(
              icon: Icons.shield_outlined,
              label: 'Role',
              value: 'Super Admin',
            ),
            const SizedBox(height: 12),
            _profileDetailRow(
              icon: Icons.verified_outlined,
              label: 'Status',
              value: 'Active',
              valueColor: const Color(0xFF10B981),
            ),

            const SizedBox(height: 28),

            // Logout button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _handleLogout();
                },
                icon: const Icon(Icons.logout_rounded, size: 20),
                label: Text(
                  'Logout',
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
              ),
            ),

            SizedBox(height: MediaQuery.of(ctx).padding.bottom + 8),
          ],
        ),
      ),
    );
  }

  Widget _profileDetailRow({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primaryNavy.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppColors.primaryNavy),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: AppColors.textLight,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  value,
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    color: valueColor ?? AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 600;
    final bool isKeyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: isWide ? null : _buildDrawer(),
      body: Stack(
        children: [
          Row(
            children: [
              // ── Fixed sidebar for wide screens ──
              if (isWide) _buildSidebar(),

              // ── Main content ──
              Expanded(
                child: SafeArea(
                  child: Column(
                    children: [
                      _buildTopBar(isWide),
                      Expanded(
                        child: _selectedIndex == 0
                            ? _buildDashboardContent()
                            : _selectedIndex == 1
                                ? _buildClassesListContent()
                                : _selectedIndex == 2
                                    ? _buildStudentsListContent()
                                    : const _AdminSettingsTab(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          
          // ── Glassmorphism Floating Bottom Bar ──
          if (!isKeyboardVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 30, // Hover above the bottom edge
              child: SafeArea(
                child: _buildFloatingBottomBar(),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Sidebar (for wide screens)
  // ─────────────────────────────────────────────

  Widget _buildSidebar() {
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: AppColors.primaryNavy,
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryNavy.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(4, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),

            // ── Logo area ──
            _buildSidebarHeader(),

            const SizedBox(height: 32),

            // ── Menu items ──
            Expanded(child: _buildSidebarMenu()),

            // ── Logout ──
            _buildSidebarLogout(),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset('assets/logo.png', fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Scholars',
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarMenu() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _sidebarItems.length,
      itemBuilder: (context, index) {
        final item = _sidebarItems[index];
        final isSelected = index == _selectedIndex;

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                if (item.isAvailable) {
                  setState(() => _selectedIndex = index);
                  final scaffoldState = Scaffold.maybeOf(context);
                  if (scaffoldState != null && scaffoldState.isDrawerOpen) {
                    Navigator.of(context).pop();
                  }
                } else {
                  _showComingSoon(item.label);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      size: 22,
                      color: isSelected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        item.label,
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                          color: isSelected
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                    if (!item.isAvailable)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.accentRed.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Soon',
                          style: GoogleFonts.poppins(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accentRed.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebarLogout() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _handleLogout,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.accentRed.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.logout_rounded,
                  size: 22,
                  color: AppColors.accentRed.withValues(alpha: 0.9),
                ),
                const SizedBox(width: 14),
                Text(
                  'Logout',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.accentRed.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Drawer (for narrow / mobile screens)
  // ─────────────────────────────────────────────

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: AppColors.primaryNavy,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            _buildSidebarHeader(),
            const SizedBox(height: 32),
            Expanded(child: _buildSidebarMenu()),
            _buildSidebarLogout(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Top bar
  // ─────────────────────────────────────────────

  Widget _buildTopBar(bool isWide) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryNavy.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          if (!isWide)
            Builder(
              builder: (ctx) => GestureDetector(
                onTap: () => Scaffold.of(ctx).openDrawer(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryNavy.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.menu_rounded,
                    color: AppColors.primaryNavy,
                    size: 22,
                  ),
                ),
              ),
            ),
          if (!isWide) const SizedBox(width: 12),
          Text(
            _sidebarItems[_selectedIndex].label,
            style: GoogleFonts.poppins(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryNavy,
            ),
          ),
          const Spacer(),
          // Admin avatar — tappable to show profile
          GestureDetector(
            onTap: _showAdminProfile,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.person_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Dashboard content
  // ─────────────────────────────────────────────

  Widget _buildDashboardContent() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      // Added extra bottom padding to account for the floating bar
      padding: const EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Welcome card ──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryNavy.withValues(alpha: 0.2),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '👋 Welcome back',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Admin Dashboard',
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Manage your institution from one place',
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── Notice Board ──
          _buildAdminNoticeBoard(),

          const SizedBox(height: 24),

          // ── Stats grid ──
          Text(
            'Overview',
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryNavy,
            ),
          ),
          const SizedBox(height: 14),

          _buildStatsGrid(),
        ],
      ),
    );
  }

  Widget _buildAdminNoticeBoard() {
    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance.ref().child('notice').onValue,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
          return const SizedBox.shrink();
        }

        final notice = Map<dynamic, dynamic>.from(
            snapshot.data!.snapshot.value as Map);
        final noticeText = notice['text']?.toString();
        final createdAt = notice['created_at'] as int?;

        if (noticeText == null || noticeText.isEmpty) {
          return const SizedBox.shrink();
        }

        String timeAgo = '';
        if (createdAt != null) {
          final diff = DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(createdAt));
          if (diff.inDays > 0) {
            timeAgo = '${diff.inDays}d ago';
          } else if (diff.inHours > 0) {
            timeAgo = '${diff.inHours}h ago';
          } else if (diff.inMinutes > 0) {
            timeAgo = '${diff.inMinutes}m ago';
          } else {
            timeAgo = 'Just now';
          }
        }

        return Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(18)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B)
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.push_pin_rounded,
                          color: Color(0xFFF59E0B),
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Active Notice',
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF92400E),
                          ),
                        ),
                      ),
                      if (timeAgo.isNotEmpty)
                        Text(
                          timeAgo,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: const Color(0xFFB45309),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          color: Color(0xFFB45309),
                          size: 20,
                        ),
                        onPressed: _deleteNotice,
                        tooltip: 'Delete Notice',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(6),
                      ),
                    ],
                  ),
                ),
                // Content
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        noticeText,
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _deleteNotice() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'Delete Notice',
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold,
            color: AppColors.primaryNavy,
          ),
        ),
        content: Text(
          'Are you sure you want to delete this notice? This action cannot be undone.',
          style: GoogleFonts.poppins(color: AppColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(
                color: AppColors.textLight,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Delete',
              style: GoogleFonts.poppins(
                color: AppColors.accentRed,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await FirebaseDatabase.instance.ref().child('notice').remove();

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(
                  'Notice deleted successfully!',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete notice: $e'),
            backgroundColor: AppColors.accentRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }
  }

  Widget _buildStatsGrid() {
    final stats = [
      _StatCard(
        icon: Icons.class_rounded,
        label: 'Classes',
        value: _classesCount.toString(),
        color: const Color(0xFFF59E0B),
      ),
      _StatCard(
        icon: Icons.person_rounded,
        label: 'Students',
        value: _studentsCount.toString(),
        color: const Color(0xFF10B981),
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1.25,
      ),
      itemCount: stats.length,
      itemBuilder: (context, index) {
        final stat = stats[index];
        return Ink(
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.divider),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryNavy.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              if (index == 0) {
                setState(() => _selectedIndex = 1); // Navigate to Classes
              } else if (index == 1) {
                setState(() => _selectedIndex = 2); // Navigate to Students
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: stat.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(stat.icon, color: stat.color, size: 20),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stat.value,
                        style: GoogleFonts.poppins(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        stat.label,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.textLight,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildClassesListContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            _isClassSearchVisible ? 10 : 20,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Registered Classes',
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryNavy,
                  ),
                ),
              ),
              IconButton(
                onPressed: _toggleClassSearch,
                icon: Icon(
                  _isClassSearchVisible
                      ? Icons.close_rounded
                      : Icons.search_rounded,
                  color: AppColors.primaryNavy,
                ),
                tooltip: _isClassSearchVisible ? 'Close Search' : 'Search Classes',
              ),
            ],
          ),
        ),
        if (_isClassSearchVisible)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: TextField(
              controller: _classSearchController,
              onChanged: (value) {
                setState(() {
                  _classSearchQuery = value;
                });
              },
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Search class, teacher, ID, or batch',
                hintStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textLight,
                ),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppColors.primaryNavy,
                ),
                suffixIcon: _classSearchQuery.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _classSearchController.clear();
                          setState(() {
                            _classSearchQuery = '';
                          });
                        },
                        icon: const Icon(Icons.close_rounded),
                        color: AppColors.textLight,
                        tooltip: 'Clear Search',
                      ),
                filled: true,
                fillColor: AppColors.cardBackground,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(
                    color: AppColors.primaryNavy,
                    width: 1.4,
                  ),
                ),
              ),
            ),
          ),
        if (_isTeachersLoading && _teachersMap == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: LinearProgressIndicator(
              backgroundColor: AppColors.divider,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryNavy),
            ),
          ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (_isTeachersLoading && _teachersMap == null) {
                return const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryNavy),
                  ),
                );
              }
              if (_teachersMap == null || _teachersMap!.isEmpty) {
                return Center(
                  child: Text(
                    'No classes registered yet.',
                    style: GoogleFonts.poppins(color: AppColors.textLight),
                  ),
                );
              }

              final teachers = _teachersMap!.entries.map((e) {
                return {'key': e.key, ...Map<String, dynamic>.from(e.value)};
              }).toList();

              // Sort by descending created_at
              teachers.sort((a, b) => (b['created_at'] as int? ?? 0)
                  .compareTo(a['created_at'] as int? ?? 0));
              final query = _classSearchQuery.trim().toLowerCase();
              final filteredTeachers = teachers
                  .where((teacher) => _matchesClassSearch(teacher, query))
                  .toList();

              if (filteredTeachers.isEmpty) {
                return Center(
                  child: Text(
                    'No classes match your search.',
                    style: GoogleFonts.poppins(color: AppColors.textLight),
                  ),
                );
              }

              return ListView.separated(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(left: 20, right: 20, bottom: 120),
                itemCount: filteredTeachers.length,
                separatorBuilder: (ctx, idx) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final t = filteredTeachers[index];
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.divider),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryNavy.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppColors.primaryNavy.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.class_rounded, color: AppColors.primaryNavy),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t['course'] ?? 'Unknown Class',
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                (t['name'] != null &&
                                        t['name'].toString().isNotEmpty &&
                                        t['name'].toString() != 'Unknown')
                                    ? 'Teacher: ${t['name']} • Class ID: ${t['class_id'] ?? ''}${t['batch'] != null ? ' • Batch: ${t['batch']}' : ''}'
                                    : 'Class ID: ${t['class_id'] ?? ''}${t['batch'] != null ? ' • Batch: ${t['batch']}' : ''}',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  color: AppColors.textLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                              padding: EdgeInsets.zero,
                              onPressed: () => _loginAsClass(t),
                              icon: const Icon(
                                Icons.login_rounded,
                                color: Color(0xFF10B981),
                              ),
                              tooltip: 'Login as Class',
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                              padding: EdgeInsets.zero,
                              onPressed: () {
                                Navigator.of(context).push(
                                  PageRouteBuilder(
                                    pageBuilder: (_, _, _) => TeacherRegistrationPage(initialData: t),
                                    transitionsBuilder: (_, animation, _, child) {
                                      return FadeTransition(opacity: animation, child: child);
                                    },
                                    transitionDuration: const Duration(milliseconds: 300),
                                  ),
                                );
                              },
                              icon: Icon(Icons.edit_rounded, color: AppColors.primaryNavy.withValues(alpha: 0.8)),
                              tooltip: 'Edit Class',
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                              padding: EdgeInsets.zero,
                              onPressed: () {
                                // Show confirmation
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    title: const Text('Delete Class?'),
                                    content: const Text('This action cannot be undone. It will delete this class and its teacher profile.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentRed),
                                        onPressed: () {
                                          Navigator.of(ctx).pop();
                                          _teachersRef.child(t['key']).remove();
                                        },
                                        child: const Text('Delete', style: TextStyle(color: Colors.white)),
                                      )
                                    ],
                                  ),
                                );
                              },
                              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.accentRed),
                              tooltip: 'Delete Class',
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStudentsListContent() {
    final bool isTeachersLoading = _isTeachersLoading && _teachersMap == null;
    final bool isStudentsLoading = _isStudentsLoading && _studentsMap == null;

    final teacherByKey = <String, Map<String, dynamic>>{};
    final teacherByClassId = <String, Map<String, dynamic>>{};

    if (_teachersMap != null) {
      for (final entry in _teachersMap!.entries) {
        if (entry.value is! Map) continue;

        final teacher = <String, dynamic>{
          'key': entry.key,
          ...Map<String, dynamic>.from(entry.value),
        };
        final key = entry.key?.toString();
        final classId = teacher['class_id']?.toString();

        if (key != null && key.isNotEmpty) {
          teacherByKey[key] = teacher;
        }
        if (classId != null && classId.isNotEmpty) {
          teacherByClassId[classId] = teacher;
        }
      }
    }

    final classOptions = _buildClassFilterOptions(teacherByClassId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Registered Students',
            style: GoogleFonts.poppins(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryNavy,
            ),
          ),
        ),
        _buildStudentFilters(classOptions),
        if (isTeachersLoading || isStudentsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: LinearProgressIndicator(
              backgroundColor: AppColors.divider,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryNavy),
            ),
          ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (isStudentsLoading) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryNavy),
                    ),
                  ),
                );
              }
              if (_studentsMap == null || _studentsMap!.isEmpty) {
                return Center(
                  child: Text(
                    'No students registered yet.',
                    style: GoogleFonts.poppins(color: AppColors.textLight),
                  ),
                );
              }

              final map = _studentsMap!;
                        final selectedClassId = classOptions.any((option) =>
                                option.classId == _selectedStudentClassId)
                            ? _selectedStudentClassId
                            : null;
                        final query = _studentSearchQuery.trim().toLowerCase();

                        final students = map.entries
                            .where((entry) => entry.value is Map)
                            .map<Map<String, dynamic>>((entry) {
                          final student = <String, dynamic>{
                            'key': entry.key,
                            ...Map<String, dynamic>.from(entry.value),
                          };
                          final className = _classNameForStudent(
                            student,
                            teacherByKey,
                            teacherByClassId,
                          );
                          return <String, dynamic>{
                            ...student,
                            '_className': className,
                          };
                        }).where((student) {
                          final classId = student['class_id']?.toString();
                          if (selectedClassId != null &&
                              classId != selectedClassId) {
                            return false;
                          }
                          return _matchesStudentSearch(
                            student,
                            student['_className']?.toString() ??
                                'Unassigned Class',
                            query,
                          );
                        }).toList();

                        students.sort((a, b) {
                          final classCompare =
                              (a['_className']?.toString() ?? '')
                                  .compareTo(b['_className']?.toString() ?? '');
                          if (classCompare != 0) return classCompare;
                          return (b['created_at'] as int? ?? 0)
                              .compareTo(a['created_at'] as int? ?? 0);
                        });

                        if (students.isEmpty) {
                          return Center(
                            child: Text(
                              'No students match your filters.',
                              style: GoogleFonts.poppins(
                                  color: AppColors.textLight),
                            ),
                          );
                        }

                        final groupedStudents =
                            <String, List<Map<String, dynamic>>>{};
                        for (final student in students) {
                          final className =
                              student['_className']?.toString() ??
                                  'Unassigned Class';
                          groupedStudents
                              .putIfAbsent(className, () => [])
                              .add(student);
                        }

                        final groups = groupedStudents.entries.toList();

                        return ListView.builder(
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.only(
                            left: 20,
                            right: 20,
                            bottom: 120,
                          ),
                          itemCount: groups.length,
                          itemBuilder: (context, groupIndex) {
                            final group = groups[groupIndex];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: EdgeInsets.only(
                                    top: groupIndex == 0 ? 0 : 18,
                                    bottom: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.class_rounded,
                                        size: 18,
                                        color: AppColors.primaryNavy,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          group.key,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.poppins(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.primaryNavy,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '${group.value.length} student${group.value.length == 1 ? '' : 's'}',
                                        style: GoogleFonts.poppins(
                                          fontSize: 11,
                                          color: AppColors.textLight,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ...List.generate(group.value.length, (index) {
                                  final student = group.value[index];
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      bottom: index == group.value.length - 1
                                          ? 0
                                          : 12,
                                    ),
                                    child: _buildStudentCard(
                                      student,
                                      student['_className']?.toString() ??
                                          group.key,
                                    ),
                                  );
                                }),
                              ],
                            );
                          },
                        );
                      }
                    ),
                  ),
                ],
              );
            }

  Widget _buildStudentFilters(List<_ClassFilterOption> classOptions) {
    final selectedClassId =
        classOptions.any((option) => option.classId == _selectedStudentClassId)
            ? _selectedStudentClassId
            : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Column(
        children: [
          TextField(
            controller: _studentSearchController,
            onChanged: (value) {
              setState(() {
                _studentSearchQuery = value;
              });
            },
            style: GoogleFonts.poppins(
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'Search student, login ID, class, or teacher',
              hintStyle: GoogleFonts.poppins(
                fontSize: 13,
                color: AppColors.textLight,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                color: AppColors.primaryNavy,
              ),
              suffixIcon: _studentSearchQuery.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _studentSearchController.clear();
                        setState(() {
                          _studentSearchQuery = '';
                        });
                      },
                      icon: const Icon(Icons.close_rounded),
                      color: AppColors.textLight,
                      tooltip: 'Clear Search',
                    ),
              filled: true,
              fillColor: AppColors.cardBackground,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(
                  color: AppColors.primaryNavy,
                  width: 1.4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: selectedClassId,
            isExpanded: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(
                Icons.filter_list_rounded,
                color: AppColors.primaryNavy,
              ),
              filled: true,
              fillColor: AppColors.cardBackground,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(
                  color: AppColors.primaryNavy,
                  width: 1.4,
                ),
              ),
            ),
            hint: Text(
              'All Classes',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            items: [
              DropdownMenuItem<String>(
                value: null,
                child: Text(
                  'All Classes',
                  style: GoogleFonts.poppins(fontSize: 13),
                ),
              ),
              ...classOptions.map(
                (option) => DropdownMenuItem<String>(
                  value: option.classId,
                  child: Text(
                    option.className,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(fontSize: 13),
                  ),
                ),
              ),
            ],
            onChanged: (value) {
              setState(() {
                _selectedStudentClassId = value;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStudentCard(Map<String, dynamic> s, String className) {
    final subtitleParts = [
      s['login_id']?.toString(),
      className,
      s['batch']?.toString(),
    ].whereType<String>().where((part) => part.trim().isNotEmpty).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryNavy.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.primaryNavy.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.person_outline_rounded,
              color: AppColors.primaryNavy,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s['name']?.toString() ?? 'Unknown',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  subtitleParts.join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: AppColors.textLight,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                padding: EdgeInsets.zero,
                onPressed: () {
                  Navigator.of(context).push(
                    PageRouteBuilder(
                      pageBuilder: (_, _, _) =>
                          StudentRegistrationPage(initialData: s),
                      transitionsBuilder: (_, animation, _, child) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                      transitionDuration: const Duration(milliseconds: 300),
                    ),
                  );
                },
                icon: Icon(
                  Icons.edit_rounded,
                  color: AppColors.primaryNavy.withValues(alpha: 0.8),
                ),
                tooltip: 'Edit',
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                padding: EdgeInsets.zero,
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      title: const Text('Delete Student?'),
                      content: const Text('This action cannot be undone.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accentRed,
                          ),
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            FirebaseDatabase.instance
                                .ref()
                                .child('students')
                                .child(s['key'])
                                .remove();
                          },
                          child: const Text(
                            'Delete',
                            style: TextStyle(color: Colors.white),
                          ),
                        )
                      ],
                    ),
                  );
                },
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.accentRed,
                ),
                tooltip: 'Delete',
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildStudentsListContentLegacy() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Registered Students',
            style: GoogleFonts.poppins(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryNavy,
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: _studentsStream,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }
              if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
                return Center(
                  child: Text(
                    'No students registered yet.',
                    style: GoogleFonts.poppins(color: AppColors.textLight),
                  ),
                );
              }

              final map = Map<dynamic, dynamic>.from(snapshot.data!.snapshot.value as Map);
              final students = map.entries.map((e) {
                return {'key': e.key, ...Map<String, dynamic>.from(e.value)};
              }).toList();

              // Sort by descending created_at
              students.sort((a, b) => (b['created_at'] as int? ?? 0).compareTo(a['created_at'] as int? ?? 0));

              return ListView.separated(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(left: 20, right: 20, bottom: 120),
                itemCount: students.length,
                separatorBuilder: (ctx, idx) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final s = students[index];
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.divider),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryNavy.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppColors.primaryNavy.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.person_outline_rounded, color: AppColors.primaryNavy),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s['name'] ?? 'Unknown',
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                               Text(
                                '${s['login_id'] ?? ''} • ${s['class_id'] ?? ''}${s['batch'] != null ? ' • ${s['batch']}' : ''}',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  color: AppColors.textLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () {
                                Navigator.of(context).push(
                                  PageRouteBuilder(
                                    pageBuilder: (_, _, _) => StudentRegistrationPage(initialData: s),
                                    transitionsBuilder: (_, animation, _, child) {
                                      return FadeTransition(opacity: animation, child: child);
                                    },
                                    transitionDuration: const Duration(milliseconds: 300),
                                  ),
                                );
                              },
                              icon: Icon(Icons.edit_rounded, color: AppColors.primaryNavy.withValues(alpha: 0.8)),
                              tooltip: 'Edit',
                            ),
                            IconButton(
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    title: const Text('Delete Student?'),
                                    content: const Text('This action cannot be undone.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentRed),
                                        onPressed: () {
                                          Navigator.of(ctx).pop();
                                          _studentsRef.child(s['key']).remove();
                                        },
                                        child: const Text('Delete', style: TextStyle(color: Colors.white)),
                                      )
                                    ],
                                  ),
                                );
                              },
                              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.accentRed),
                              tooltip: 'Delete',
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  //  Notice creation sheet
  // ─────────────────────────────────────────────

  void _showNoticeSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _PostNoticeSheet(),
    );
  }

  Widget _buildFloatingBottomBar() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        constraints: const BoxConstraints(maxWidth: 420),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(35),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                // Using a slightly transparent dark primary color to simulate tinted glass
                color: AppColors.primaryNavy.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(35),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryNavy.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildBottomBarItem(
                    Icons.home_rounded, 
                    'Home', 
                    _selectedIndex == 0,
                    onTap: () {
                      setState(() {
                        _selectedIndex = 0;
                      });
                    },
                  ),
                  _buildBottomBarItem(
                    Icons.campaign_rounded, 
                    'Notice', 
                    false,
                    onTap: _showNoticeSheet,
                  ),
                  _buildBottomBarItem(
                    Icons.class_rounded, 
                    'Add Class', 
                    false,
                    onTap: () {
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder: (_, _, _) => const TeacherRegistrationPage(),
                          transitionsBuilder: (_, animation, _, child) {
                            return FadeTransition(opacity: animation, child: child);
                          },
                          transitionDuration: const Duration(milliseconds: 300),
                        ),
                      );
                    },
                  ),
                  _buildBottomBarItem(
                    Icons.group_add_rounded, 
                    'Add Student', 
                    false,
                    onTap: () {
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder: (_, _, _) => const StudentRegistrationPage(),
                          transitionsBuilder: (_, animation, _, child) {
                            return FadeTransition(opacity: animation, child: child);
                          },
                          transitionDuration: const Duration(milliseconds: 300),
                        ),
                      );
                    },
                  ),
                  _buildBottomBarItem(Icons.person_rounded, 'Profile', false, onTap: _showAdminProfile),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBarItem(IconData icon, String label, bool isActive, {VoidCallback? onTap}) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap ?? () => _showComingSoon(label),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isActive ? Colors.white.withValues(alpha: 0.15) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                icon,
                color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.8),
                size: 24,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  Data models
// ─────────────────────────────────────────────

class _SidebarItem {
  final IconData icon;
  final String label;
  final bool isAvailable;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.isAvailable,
  });
}

class _StatCard {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
}

class _ClassFilterOption {
  final String classId;
  final String className;

  const _ClassFilterOption({
    required this.classId,
    required this.className,
  });
}

// ─────────────────────────────────────────────
//  Notice Creation Bottom Sheet Widget (Text-Only)
// ─────────────────────────────────────────────

class _PostNoticeSheet extends StatefulWidget {
  const _PostNoticeSheet();

  @override
  State<_PostNoticeSheet> createState() => _PostNoticeSheetState();
}

class _PostNoticeSheetState extends State<_PostNoticeSheet> {
  final _noticeTextController = TextEditingController();
  bool _isPosting = false;

  @override
  void dispose() {
    _noticeTextController.dispose();
    super.dispose();
  }

  Future<void> _postNotice() async {
    final text = _noticeTextController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Text(
                'Please enter notice text.',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
              ),
            ],
          ),
          backgroundColor: AppColors.accentRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ),
      );
      return;
    }

    setState(() => _isPosting = true);
    debugPrint('[Notice] Starting postNotice flow (Text-Only)...');

    try {
      debugPrint('[Notice] Saving notice data to database...');
      final noticeData = <String, dynamic>{
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'text': text,
      };

      await FirebaseDatabase.instance
          .ref()
          .child('notice')
          .set(noticeData);
      debugPrint('[Notice] Notice saved successfully to database.');

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(
                  'Notice posted successfully!',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Notice] Error in postNotice: $e');
      if (mounted) {
        setState(() => _isPosting = false);
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to post notice: $e'),
            backgroundColor: AppColors.accentRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.campaign_rounded,
                    color: Color(0xFFF59E0B),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Post Notice',
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryNavy,
                        ),
                      ),
                      Text(
                        'Visible to all students & teachers',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.textLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),

          // Text field
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notice Text',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _noticeTextController,
                    maxLines: 4,
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Type your notice here...',
                      hintStyle: GoogleFonts.poppins(
                        fontSize: 14,
                        color: AppColors.textLight,
                      ),
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.all(16),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: AppColors.divider),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: AppColors.primaryNavy,
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // Post button
          Padding(
            padding: EdgeInsets.fromLTRB(
                24, 8, 24, MediaQuery.of(context).padding.bottom + 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _isPosting ? null : _postNotice,
                icon: _isPosting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 20),
                label: Text(
                  _isPosting ? 'Posting...' : 'Post Notice',
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryNavy,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  Admin Settings Tab Widget (Common Paper)
// ─────────────────────────────────────────────

class _AdminSettingsTab extends StatefulWidget {
  const _AdminSettingsTab();

  @override
  State<_AdminSettingsTab> createState() => _AdminSettingsTabState();
}

class _AdminSettingsTabState extends State<_AdminSettingsTab> {
  final _formKey = GlobalKey<FormState>();
  final _classNameController = TextEditingController();
  final _commonClassIdController = TextEditingController();
  final _targetClassIdsController = TextEditingController();

  late final Stream<DatabaseEvent> _teachersStream =
      FirebaseDatabase.instance.ref().child('teachers').onValue.asBroadcastStream();

  String _targetType = 'class'; // 'class' or 'student'
  bool _isLoading = false;
  String _commonClassId = '';

  List<Map<String, dynamic>> _classesList = [];
  List<Map<String, dynamic>> _studentsList = [];
  bool _isLoadingDropdownData = true;

  final List<Map<String, dynamic>> _selectedClasses = [];
  final List<Map<String, dynamic>> _selectedStudents = [];
  final Set<String> _autoClassIds = {};
  TextEditingController? _classSearchTextController;
  TextEditingController? _studentSearchTextController;

  @override
  void initState() {
    super.initState();
    _generateCommonClassId();
    _fetchDropdownData();
  }

  void _generateCommonClassId() {
    setState(() {
      _commonClassId = 'CLS-${Random().nextInt(9000) + 1000}';
      _commonClassIdController.text = _commonClassId;
    });
  }

  @override
  void dispose() {
    _classNameController.dispose();
    _commonClassIdController.dispose();
    _targetClassIdsController.dispose();
    super.dispose();
  }

  Future<void> _fetchDropdownData() async {
    try {
      final teachersSnapshot = await FirebaseDatabase.instance.ref().child('teachers').get();
      final List<Map<String, dynamic>> tempClasses = [];
      if (teachersSnapshot.value != null) {
        final map = Map<dynamic, dynamic>.from(teachersSnapshot.value as Map);
        for (var entry in map.entries) {
          final data = Map<String, dynamic>.from(entry.value);
          // Only list non-common classes as potential targets
          if (data['is_common'] != true) {
            tempClasses.add({
              'key': entry.key,
              'class_id': data['class_id'] ?? '',
              'course': data['course'] ?? '',
            });
          }
        }
      }

      final studentsSnapshot = await FirebaseDatabase.instance.ref().child('students').get();
      final List<Map<String, dynamic>> tempStudents = [];
      if (studentsSnapshot.value != null) {
        final map = Map<dynamic, dynamic>.from(studentsSnapshot.value as Map);
        for (var entry in map.entries) {
          final data = Map<String, dynamic>.from(entry.value);
          tempStudents.add({
            'key': entry.key,
            'name': data['name'] ?? '',
            'class_id': data['class_id'] ?? '',
            'login_id': data['login_id'] ?? '',
          });
        }
      }

      if (mounted) {
        setState(() {
          _classesList = tempClasses;
          _studentsList = tempStudents;
          _isLoadingDropdownData = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching dropdown data: $e');
      if (mounted) {
        setState(() => _isLoadingDropdownData = false);
      }
    }
  }

  Future<void> _submitCommonClass() async {
    if (!_formKey.currentState!.validate()) return;

    if (_targetType == 'class' && _selectedClasses.isEmpty) {
      _showSnackBar('Please select at least one target Class/Course.', isError: true);
      return;
    }
    if (_targetType == 'student' && _selectedStudents.isEmpty) {
      _showSnackBar('Please select at least one target Student.', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final dbRef = FirebaseDatabase.instance.ref().child('teachers');
      final newClassRef = dbRef.push();

      Map<String, bool>? classIdsMap;
      Map<String, bool>? studentIdsMap;
      String? studentNames;
      String? classIdDisplay;

      if (_targetType == 'class') {
        classIdsMap = {
          for (var c in _selectedClasses) c['class_id']: true
        };
        classIdDisplay = _selectedClasses.map((c) => c['class_id']).join(', ');
      } else {
        studentIdsMap = {
          for (var s in _selectedStudents) s['key']: true
        };
        classIdsMap = {
          for (var s in _selectedStudents) s['class_id']: true
        };
        studentNames = _selectedStudents.map((s) => s['name']).join(', ');
        classIdDisplay = _selectedStudents.map((s) => s['class_id']).join(', ');
      }

      final currentYear = DateTime.now().year;
      final defaultBatch = '$currentYear - ${currentYear + 1}';

      await newClassRef.set({
        'id': newClassRef.key,
        'course': _classNameController.text.trim(),
        'batch': defaultBatch,
        'class_id': _commonClassId,
        'is_common': true,
        'target_type': _targetType,
        'class_ids': classIdsMap,
        'student_ids': studentIdsMap,
        'student_names': studentNames,
        'class_id_display': classIdDisplay,
        'created_at': ServerValue.timestamp,
      });

      _classNameController.clear();
      _targetClassIdsController.clear();
      _classSearchTextController?.clear();
      _studentSearchTextController?.clear();
      
      setState(() {
        _selectedClasses.clear();
        _selectedStudents.clear();
        _autoClassIds.clear();
        _generateCommonClassId();
        _isLoading = false;
      });

      _showSnackBar('Common Class created successfully!');
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Failed to create common class: $e', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.accentRed : const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.poppins(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool readOnly = false,
    FocusNode? focusNode,
    int? minLines,
    int? maxLines,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      readOnly: readOnly,
      focusNode: focusNode,
      minLines: minLines,
      maxLines: maxLines,
      style: GoogleFonts.poppins(
        fontSize: 14,
        color: readOnly ? AppColors.textLight : AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.poppins(
          fontSize: 13,
          color: AppColors.textLight.withValues(alpha: 0.6),
        ),
        prefixIcon: Icon(icon, size: 18, color: AppColors.textLight),
        filled: true,
        fillColor: readOnly ? AppColors.divider.withValues(alpha: 0.2) : AppColors.cardBackground,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primaryNavy, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accentRed),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accentRed, width: 1.5),
        ),
      ),
      validator: validator,
    );
  }

  Widget _buildActiveCommonClassesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Active Common Classes',
          style: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryNavy,
          ),
        ),
        const SizedBox(height: 12),
        StreamBuilder<DatabaseEvent>(
          stream: _teachersStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text('Error: ${snapshot.error}');
            }
            if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
              return Text(
                'No common classes created yet.',
                style: GoogleFonts.poppins(color: AppColors.textLight, fontSize: 13),
              );
            }

            final map = Map<dynamic, dynamic>.from(snapshot.data!.snapshot.value as Map);
            final list = map.entries.map((e) {
              return {'key': e.key, ...Map<String, dynamic>.from(e.value)};
            }).where((item) => item['is_common'] == true).toList();

            if (list.isEmpty) {
              return Text(
                'No common classes created yet.',
                style: GoogleFonts.poppins(color: AppColors.textLight, fontSize: 13),
              );
            }

            list.sort((a, b) => (b['created_at'] as int? ?? 0).compareTo(a['created_at'] as int? ?? 0));

            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = list[index];
                final isClass = item['target_type'] == 'class';
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.cardBackground,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.primaryNavy.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.people_outline_rounded, color: AppColors.primaryNavy, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['course'] ?? 'No Name',
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              'Class ID: ${item['class_id'] ?? ''}',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: AppColors.textLight,
                              ),
                            ),
                            const SizedBox(height: 2),
                            if (isClass)
                              Text(
                                'Target: Classes (${item['class_id_display'] ?? item['class_id'] ?? ''})',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  color: AppColors.primaryNavy.withValues(alpha: 0.8),
                                ),
                              ),
                            if (!isClass)
                              Text(
                                'Target: Students (${item['student_names'] ?? item['student_name'] ?? ''})',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  color: AppColors.primaryNavy.withValues(alpha: 0.8),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.accentRed, size: 20),
                        onPressed: () {
                          FirebaseDatabase.instance.ref().child('teachers').child(item['key']).remove();
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return _isLoadingDropdownData
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Create Common Class',
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 16),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLabel('Target Audience'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() {
                                _targetType = 'class';
                                _selectedStudents.clear();
                                _autoClassIds.clear();
                                _targetClassIdsController.clear();
                              }),
                              child: Container(
                                height: 46,
                                decoration: BoxDecoration(
                                  color: _targetType == 'class' ? AppColors.primaryNavy : AppColors.cardBackground,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.divider),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'Whole Class',
                                  style: GoogleFonts.poppins(
                                    color: _targetType == 'class' ? Colors.white : AppColors.textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() {
                                _targetType = 'student';
                                _selectedClasses.clear();
                                _autoClassIds.clear();
                                _targetClassIdsController.clear();
                              }),
                              child: Container(
                                height: 46,
                                decoration: BoxDecoration(
                                  color: _targetType == 'student' ? AppColors.primaryNavy : AppColors.cardBackground,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.divider),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'Specific Student',
                                  style: GoogleFonts.poppins(
                                    color: _targetType == 'student' ? Colors.white : AppColors.textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      if (_targetType == 'class') ...[
                        _buildLabel('Select Classes'),
                        const SizedBox(height: 8),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return Autocomplete<Map<String, dynamic>>(
                              initialValue: const TextEditingValue(text: ''),
                              displayStringForOption: (item) => '',
                              optionsBuilder: (TextEditingValue textEditingValue) {
                                return _classesList.where((item) =>
                                    item['course'].toLowerCase().contains(textEditingValue.text.toLowerCase()) ||
                                    item['class_id'].toLowerCase().contains(textEditingValue.text.toLowerCase()));
                              },
                              onSelected: (Map<String, dynamic> selection) {
                                setState(() {
                                  if (!_selectedClasses.any((c) => c['class_id'] == selection['class_id'])) {
                                    _selectedClasses.add(selection);
                                    _autoClassIds.add(selection['class_id']);
                                    _targetClassIdsController.text = _autoClassIds.join(', ');
                                  }
                                });
                                _classSearchTextController?.clear();
                                FocusScope.of(context).unfocus();
                              },
                              fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                                _classSearchTextController = textEditingController;
                                return _buildTextField(
                                  controller: textEditingController,
                                  focusNode: focusNode,
                                  hint: 'Search and select class...',
                                  icon: Icons.search_rounded,
                                  validator: (v) => _selectedClasses.isEmpty ? 'At least one class is required' : null,
                                );
                              },
                              optionsViewBuilder: (context, onSelected, options) {
                                return Align(
                                  alignment: Alignment.topLeft,
                                  child: Material(
                                    elevation: 4,
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      width: constraints.maxWidth,
                                      constraints: const BoxConstraints(maxHeight: 200),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: AppColors.divider),
                                      ),
                                      child: ListView.builder(
                                        padding: EdgeInsets.zero,
                                        itemCount: options.length,
                                        itemBuilder: (BuildContext context, int index) {
                                          final option = options.elementAt(index);
                                          return ListTile(
                                            title: Text(
                                              option['course'],
                                              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600),
                                            ),
                                            subtitle: Text(
                                              'Class ID: ${option['class_id']}',
                                              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textLight),
                                            ),
                                            onTap: () => onSelected(option),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        if (_selectedClasses.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _selectedClasses.map((cls) {
                              return Chip(
                                label: Text(
                                  '${cls['course']} (${cls['class_id']})',
                                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.primaryNavy, fontWeight: FontWeight.w500),
                                ),
                                backgroundColor: AppColors.primaryNavy.withValues(alpha: 0.08),
                                deleteIcon: const Icon(Icons.close_rounded, size: 16, color: AppColors.primaryNavy),
                                onDeleted: () {
                                  setState(() {
                                    _selectedClasses.remove(cls);
                                    _autoClassIds.remove(cls['class_id']);
                                    _targetClassIdsController.text = _autoClassIds.join(', ');
                                  });
                                },
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                side: BorderSide(color: AppColors.primaryNavy.withValues(alpha: 0.2)),
                              );
                            }).toList(),
                          ),
                        ],
                      ] else ...[
                        _buildLabel('Select Students'),
                        const SizedBox(height: 8),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return Autocomplete<Map<String, dynamic>>(
                              initialValue: const TextEditingValue(text: ''),
                              displayStringForOption: (item) => '',
                              optionsBuilder: (TextEditingValue textEditingValue) {
                                return _studentsList.where((item) =>
                                    item['name'].toLowerCase().contains(textEditingValue.text.toLowerCase()) ||
                                    item['login_id'].toLowerCase().contains(textEditingValue.text.toLowerCase()));
                              },
                              onSelected: (Map<String, dynamic> selection) {
                                setState(() {
                                  if (!_selectedStudents.any((s) => s['key'] == selection['key'])) {
                                    _selectedStudents.add(selection);
                                    _autoClassIds.add(selection['class_id']);
                                    _targetClassIdsController.text = _autoClassIds.join(', ');
                                  }
                                });
                                _studentSearchTextController?.clear();
                                FocusScope.of(context).unfocus();
                              },
                              fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                                _studentSearchTextController = textEditingController;
                                return _buildTextField(
                                  controller: textEditingController,
                                  focusNode: focusNode,
                                  hint: 'Search and select student...',
                                  icon: Icons.search_rounded,
                                  validator: (v) => _selectedStudents.isEmpty ? 'At least one student is required' : null,
                                );
                              },
                              optionsViewBuilder: (context, onSelected, options) {
                                return Align(
                                  alignment: Alignment.topLeft,
                                  child: Material(
                                    elevation: 4,
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      width: constraints.maxWidth,
                                      constraints: const BoxConstraints(maxHeight: 200),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: AppColors.divider),
                                      ),
                                      child: ListView.builder(
                                        padding: EdgeInsets.zero,
                                        itemCount: options.length,
                                        itemBuilder: (BuildContext context, int index) {
                                          final option = options.elementAt(index);
                                          return ListTile(
                                            title: Text(
                                              option['name'],
                                              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600),
                                            ),
                                            subtitle: Text(
                                              'Class ID: ${option['class_id']} • Student ID: ${option['login_id']}',
                                              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textLight),
                                            ),
                                            onTap: () => onSelected(option),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        if (_selectedStudents.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _selectedStudents.map((stud) {
                              return Chip(
                                label: Text(
                                  '${stud['name']} (${stud['login_id']})',
                                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.primaryNavy, fontWeight: FontWeight.w500),
                                ),
                                backgroundColor: AppColors.primaryNavy.withValues(alpha: 0.08),
                                deleteIcon: const Icon(Icons.close_rounded, size: 16, color: AppColors.primaryNavy),
                                onDeleted: () {
                                  setState(() {
                                    _selectedStudents.remove(stud);
                                    _autoClassIds.clear();
                                    for (var s in _selectedStudents) {
                                      _autoClassIds.add(s['class_id']);
                                    }
                                    _targetClassIdsController.text = _autoClassIds.join(', ');
                                  });
                                },
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                side: BorderSide(color: AppColors.primaryNavy.withValues(alpha: 0.2)),
                              );
                            }).toList(),
                          ),
                        ],
                      ],

                      const SizedBox(height: 20),

                      _buildLabel('Target Class IDs (Auto-filled)'),
                      const SizedBox(height: 8),
                      _buildTextField(
                        controller: _targetClassIdsController,
                        hint: 'Populates automatically',
                        icon: Icons.badge_outlined,
                        readOnly: true,
                        validator: (v) => v == null || v.trim().isEmpty ? 'Class ID is required' : null,
                      ),

                      const SizedBox(height: 20),

                      _buildLabel('Common Class ID (Auto-generated)'),
                      const SizedBox(height: 8),
                      _buildTextField(
                        controller: _commonClassIdController,
                        hint: '',
                        icon: Icons.vpn_key_rounded,
                        readOnly: true,
                      ),

                      const SizedBox(height: 20),

                      _buildLabel('Class / Course Name'),
                      const SizedBox(height: 8),
                      _buildTextField(
                        controller: _classNameController,
                        hint: 'e.g. Mathematics II',
                        icon: Icons.menu_book_rounded,
                        validator: (v) => v == null || v.trim().isEmpty ? 'Enter class/course name' : null,
                      ),

                      const SizedBox(height: 30),

                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _submitCommonClass,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryNavy,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : Text(
                                  'Create Common Class',
                                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                const Divider(),
                const SizedBox(height: 30),
                _buildActiveCommonClassesSection(),
                const SizedBox(height: 100),
              ],
            ),
          );
  }
}

