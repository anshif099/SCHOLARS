import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../services/call_notification_service.dart';
import '../theme/app_theme.dart';
import 'landing_page.dart';
import 'live_video_room_page.dart';
import 'video_player_page.dart';
import '../services/permission_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'note_image_viewer_page.dart';
import '../services/firebase_upload_auth_service.dart';
import '../components/fresh_stream_builder.dart';
import '../components/universal_image.dart';

class StudentDashboardPage extends StatefulWidget {
  final Map<dynamic, dynamic> studentData;
  final bool showNotificationWarning;

  const StudentDashboardPage({
    super.key,
    required this.studentData,
    this.showNotificationWarning = false,
  });

  @override
  State<StudentDashboardPage> createState() => _StudentDashboardPageState();
}

class _StudentDashboardPageState extends State<StudentDashboardPage> {
  int _selectedIndex = 0;
  final Set<String> _myCommonClassIds = {};
  StreamSubscription<DatabaseEvent>? _teachersSub;

  bool _isStudentTargeted(Map<dynamic, dynamic> commonClass) {
    final targetType = commonClass['target_type']?.toString();
    final myClassId = widget.studentData['class_id']?.toString().trim();
    final myStudentKey = widget.studentData['key']?.toString().trim();
    
    if (targetType == 'class') {
      final classIdsMap = commonClass['class_ids'] as Map?;
      return classIdsMap != null && classIdsMap.containsKey(myClassId);
    } else if (targetType == 'student') {
      final studentIdsMap = commonClass['student_ids'] as Map?;
      return studentIdsMap != null && studentIdsMap.containsKey(myStudentKey);
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await PermissionService.requestAllPermissions();
      _ensureCallNotificationsReady(showResult: widget.showNotificationWarning);
    });

    _teachersSub = FirebaseDatabase.instance
        .ref()
        .child('teachers')
        .onValue
        .listen((event) {
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> map = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        final newCommonIds = <String>{};
        for (var entry in map.entries) {
          final data = Map<dynamic, dynamic>.from(entry.value as Map);
          if (data['is_common'] == true && _isStudentTargeted(data)) {
            final classId = data['class_id']?.toString();
            if (classId != null && classId.isNotEmpty) {
              newCommonIds.add(classId);
            }
          }
        }
        if (mounted) {
          setState(() {
            _myCommonClassIds.clear();
            _myCommonClassIds.addAll(newCommonIds);
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _teachersSub?.cancel();
    super.dispose();
  }

  Future<void> _ensureCallNotificationsReady({required bool showResult}) async {
    final studentKey = widget.studentData['key']?.toString();
    if (studentKey == null || studentKey.isEmpty) {
      return;
    }

    var notificationsReady = false;
    try {
      notificationsReady = await CallNotificationService.activateForStudent(
        studentKey,
      );
    } catch (e) {
      debugPrint('Student dashboard notification retry skipped: $e');
      notificationsReady = await CallNotificationService.hasSavedToken(
        studentKey,
      );
    }

    if (!mounted || !showResult) {
      return;
    }

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              notificationsReady
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_off_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                notificationsReady
                    ? 'Class notifications are enabled.'
                    : 'Allow notifications to receive class live alerts.',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: notificationsReady
            ? AppColors.primaryNavy
            : AppColors.accentRed,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
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

  void _showNoLiveClass() {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.videocam_off_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Text(
              'No live class available',
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
          'Are you sure you want to log out of your student portal?',
          style: GoogleFonts.poppins(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(color: AppColors.textLight),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await CallNotificationService.deactivateStudentSession();
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('is_student_logged_in');
              await prefs.remove('student_data');
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LandingPage()),
                  (route) => false,
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentRed,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'Logout',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showStudentProfile() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 30),
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: AppColors.primaryNavy.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.person_rounded,
                size: 50,
                color: AppColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              widget.studentData['name'] ?? 'Student',
              style: GoogleFonts.poppins(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryNavy,
              ),
            ),
            Text(
              'Enrolled in ${widget.studentData['class_id'] ?? ''}',
              style: GoogleFonts.poppins(
                fontSize: 15,
                color: AppColors.textLight,
              ),
            ),
            const SizedBox(height: 30),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(
                children: [
                  _buildProfileRow(
                    Icons.email_rounded,
                    widget.studentData['email'] ?? 'No email',
                  ),
                  const Divider(height: 30),
                  _buildProfileRow(
                    Icons.phone_rounded,
                    widget.studentData['mobile'] ?? 'No mobile',
                  ),
                  const Divider(height: 30),
                  _buildProfileRow(
                    Icons.badge_rounded,
                    'Login ID: ${widget.studentData['login_id'] ?? 'N/A'}',
                  ),
                  if (widget.studentData['teacher_name'] != null &&
                      widget.studentData['teacher_name'].toString().isNotEmpty &&
                      widget.studentData['teacher_name'].toString() != 'Unknown') ...[
                    const Divider(height: 30),
                    _buildProfileRow(
                      Icons.assignment_ind_rounded,
                      'Educator: ${widget.studentData['teacher_name']}',
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 30),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _handleLogout();
                  },
                  icon: const Icon(
                    Icons.logout_rounded,
                    color: AppColors.accentRed,
                  ),
                  label: Text(
                    'Logout',
                    style: GoogleFonts.poppins(
                      color: AppColors.accentRed,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: AppColors.accentRed.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: AppColors.textLight, size: 20),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 15,
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _joinCall(String classId, String topic) async {
    bool granted = await PermissionService.requestCameraAndMic();
    if (granted) {
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LiveVideoRoomPage(
              isTeacher: false,
              classId: classId,
              topic: topic,
              participantId: widget.studentData['key']?.toString(),
              participantName: widget.studentData['name']?.toString(),
            ),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Camera and Microphone permissions are required to join the class.',
            ),
          ),
        );
      }
    }
  }

  Widget _buildCommonClassesSection() {
    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance.ref().child('teachers').onValue,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
          return const SizedBox.shrink();
        }

        final map = Map<dynamic, dynamic>.from(snapshot.data!.snapshot.value as Map);
        final commonClassesList = map.entries
            .map((e) => {'key': e.key, ...Map<dynamic, dynamic>.from(e.value)})
            .where((item) => item['is_common'] == true && _isStudentTargeted(item))
            .toList();

        if (commonClassesList.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 30),
            Text(
              'Common Classes',
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: commonClassesList.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final commonClass = commonClassesList[index];
                  final className = commonClass['course'] ?? 'Unnamed Class';
                  final classId = commonClass['class_id'] ?? '';

                  return GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CommonClassSubjectsPage(
                            commonClassName: className,
                            commonClassId: classId,
                            studentData: widget.studentData,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      width: 150,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.divider),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryNavy.withValues(alpha: 0.02),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Icon(
                            Icons.groups_rounded,
                            color: Color(0xFF10B981),
                            size: 40,
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                className,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: AppColors.primaryNavy,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'ID: $classId',
                                style: GoogleFonts.poppins(
                                  fontSize: 10,
                                  color: AppColors.textLight,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isKeyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: _selectedIndex == 0
                      ? _buildDashboardContent()
                      : const Center(child: Text('Coming Soon')),
                ),
              ],
            ),
          ),
          // Glassmorphism Bottom Bar
          if (!isKeyboardVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 30,
              child: SafeArea(child: _buildFloatingBottomBar()),
            ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Welcome,',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  color: AppColors.textLight,
                ),
              ),
              Text(
                widget.studentData['name']?.split(' ')[0] ?? 'Student',
                style: GoogleFonts.poppins(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryNavy,
                ),
              ),
            ],
          ),
          GestureDetector(
            onTap: _showStudentProfile,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryNavy.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(
                Icons.person_outline_rounded,
                color: AppColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardContent() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 120),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.primaryNavy, Color(0xFF1E2840)],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryNavy.withValues(alpha: 0.3),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: FutureBuilder<DatabaseEvent>(
            future: FirebaseDatabase.instance
                .ref()
                .child('teachers')
                .child(widget.studentData['teacher_id'] ?? '')
                .once(),
            builder: (context, snapshot) {
              String className =
                  widget.studentData['class_id'] ?? 'Unknown Class';
              String educatorName = widget.studentData['teacher_name'] ?? 'N/A';

              if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                final tData = Map<dynamic, dynamic>.from(
                  snapshot.data!.snapshot.value as Map,
                );
                if (tData['course'] != null &&
                    tData['course'].toString().isNotEmpty) {
                  className = tData['course'].toString();
                }
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your Class',
                    style: GoogleFonts.poppins(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    className,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  if (educatorName != 'N/A' &&
                      educatorName != 'Unknown' &&
                      educatorName.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Educator: $educatorName',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),

        // ── Notice Board ──
        StreamBuilder<DatabaseEvent>(
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
              padding: const EdgeInsets.only(top: 30),
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
                          horizontal: 16, vertical: 12),
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
                              'Notice Board',
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
        ),

        // Live Class Stream Wrapper
        StreamBuilder<DatabaseEvent>(
          stream: FirebaseDatabase.instance.ref().child('live_classes').onValue,
          builder: (context, snapshot) {
            final List<Widget> liveCards = [];
            final myMainClassId = widget.studentData['class_id']?.toString() ?? '';

            if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
              final parentMap = Map<dynamic, dynamic>.from(snapshot.data!.snapshot.value as Map);
              for (var entry in parentMap.entries) {
                final classId = entry.key.toString();
                final classData = Map<dynamic, dynamic>.from(entry.value as Map);
                
                final isLive = classData['is_live'] == true;
                final liveTopic = classData['topic'] ?? 'Live Class';
                
                if (isLive && (classId == myMainClassId || _myCommonClassIds.contains(classId))) {
                  liveCards.add(
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: GestureDetector(
                        onTap: () => _joinCall(classId, liveTopic),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: AppColors.accentRed.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.accentRed, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accentRed.withValues(alpha: 0.2),
                                blurRadius: 15,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: const BoxDecoration(
                                  color: AppColors.accentRed,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.videocam_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: AppColors.accentRed,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'LIVE NOW',
                                          style: GoogleFonts.poppins(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: AppColors.accentRed,
                                            letterSpacing: 1,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      liveTopic,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.poppins(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryNavy,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_ios_rounded,
                                color: AppColors.accentRed,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }
              }
            }

            if (liveCards.isEmpty) return const SizedBox.shrink();
            return Column(children: liveCards);
          },
        ),

        const SizedBox(height: 30),
        Text(
          'Subjects',
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryNavy,
          ),
        ),
        const SizedBox(height: 16),
        _buildRecordedClassesList(),
        _buildCommonClassesSection(),

        const SizedBox(height: 30),
        Text(
          'Quick Actions',
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryNavy,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () async {
                  final mainClassId = widget.studentData['class_id'];
                  if (mainClassId != null) {
                    final snapshot = await FirebaseDatabase.instance
                        .ref()
                        .child('live_classes')
                        .child(mainClassId)
                        .get();
                    if (snapshot.exists) {
                      final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
                      if (data['is_live'] == true) {
                        _joinCall(mainClassId, data['topic'] ?? 'Live Class');
                        return;
                      }
                    }
                  }

                  for (var commonClassId in _myCommonClassIds) {
                    final snapshot = await FirebaseDatabase.instance
                        .ref()
                        .child('live_classes')
                        .child(commonClassId)
                        .get();
                    if (snapshot.exists) {
                      final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
                      if (data['is_live'] == true) {
                        _joinCall(commonClassId, data['topic'] ?? 'Live Class');
                        return;
                      }
                    }
                  }

                  _showNoLiveClass();
                },
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.video_camera_front_rounded,
                        color: AppColors.primaryNavy,
                        size: 32,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Join',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryNavy,
                        ),
                      ),
                      Text(
                        'Classroom',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          color: AppColors.textLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: GestureDetector(
                onTap: () => _showComingSoon('Assignments'),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.assignment_rounded,
                        color: AppColors.accentRed,
                        size: 32,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Tasks',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryNavy,
                        ),
                      ),
                      Text(
                        'Assignments',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          color: AppColors.textLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),


      ],
    );
  }

  bool _hasPlayableRecording(Map<String, dynamic> recording) {
    final hasUrl =
        recording['video_url'] != null &&
        recording['video_url'].toString().isNotEmpty;
    final hasBase64 =
        recording['video_base64'] != null &&
        recording['video_base64'].toString().isNotEmpty;
    return hasUrl || hasBase64;
  }

  String? _recordingStatusLabel(Map<String, dynamic> recording) {
    if (_hasPlayableRecording(recording)) return null;

    final status = recording['upload_status']?.toString();
    if (status == 'preparing' || status == 'uploading') {
      return 'Uploading';
    }
    return 'Upload failed';
  }

  IconData _recordingIcon(Map<String, dynamic> recording) {
    if (_hasPlayableRecording(recording)) {
      return Icons.play_circle_fill_rounded;
    }

    final status = recording['upload_status']?.toString();
    if (status == 'preparing' || status == 'uploading') {
      return Icons.cloud_upload_rounded;
    }
    return Icons.cloud_off_rounded;
  }

  String _recordingUnavailableMessage(Map<String, dynamic> recording) {
    final status = recording['upload_status']?.toString();
    if (status == 'preparing' || status == 'uploading') {
      return 'Video is still uploading. Try again shortly.';
    }

    final error = recording['upload_error']?.toString();
    if (error != null && error.isNotEmpty) {
      return 'Video upload failed: $error';
    }

    return 'This recording has no video file available.';
  }

  Widget _buildRecordedClassesList() {
    final classId = widget.studentData['class_id'] ?? '';
    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance.ref().child('subjects').child(classId).onValue,
      builder: (context, subjectsSnapshot) {
        return StreamBuilder<DatabaseEvent>(
          stream: FirebaseDatabase.instance.ref().child('recorded_classes').child(classId).onValue,
          builder: (context, recordingsSnapshot) {
            List<Map<String, dynamic>> subjectsList = [];

            if (subjectsSnapshot.hasData && subjectsSnapshot.data!.snapshot.value != null) {
              final map = Map<dynamic, dynamic>.from(subjectsSnapshot.data!.snapshot.value as Map);
              final list = map.entries.map((e) => {
                'key': e.key,
                ...Map<String, dynamic>.from(e.value)
              }).toList();
              list.sort((a, b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
              subjectsList.addAll(list);
            }

            List<Map<String, dynamic>> recordingsList = [];
            if (recordingsSnapshot.hasData && recordingsSnapshot.data!.snapshot.value != null) {
              final map = Map<dynamic, dynamic>.from(recordingsSnapshot.data!.snapshot.value as Map);
              recordingsList = map.entries
                  .map((e) => Map<String, dynamic>.from(e.value))
                  .toList();
            }

            final Map<String, List<Map<String, dynamic>>> groupedRecordings = {};
            for (var rc in recordingsList) {
              final subId = rc['subject_id']?.toString();
              if (subId != null) {
                groupedRecordings.putIfAbsent(subId, () => []).add(rc);
              }
            }

            if (subjectsList.isEmpty) {
              return Container(
                height: 140,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.cardBackground,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Text(
                  'No subjects or recorded lectures available yet.',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    color: AppColors.textLight,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            }

            return SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: subjectsList.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final subject = subjectsList[index];
                  final subjectName = subject['name'] ?? 'Unnamed Subject';
                  final subjectKey = subject['key'] ?? '';
                  final subjectRecordings = groupedRecordings[subjectKey] ?? [];
                  final count = subjectRecordings.length;

                  return GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SubjectRecordingsPage(
                            subjectName: subjectName,
                            isTeacher: false,
                            classId: classId,
                            participantId: widget.studentData['key']?.toString() ?? '',
                            subjectKey: subjectKey,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      width: 140,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.divider),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryNavy.withValues(alpha: 0.02),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Icon(
                            Icons.folder_rounded,
                            color: Color(0xFFF59E0B),
                            size: 40,
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                subjectName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: AppColors.primaryNavy,
                                ),
                              ),
                              Text(
                                '$count recordings',
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  color: AppColors.textLight,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          }
        );
      }
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
                    onTap: () => setState(() => _selectedIndex = 0),
                  ),
                  _buildBottomBarItem(
                    Icons.video_camera_front_rounded,
                    'Attend Class',
                    false,
                    onTap: () async {
                      final classId = widget.studentData['class_id'];
                      if (classId != null) {
                        final snapshot = await FirebaseDatabase.instance
                            .ref()
                            .child('live_classes')
                            .child(classId)
                            .get();
                        if (snapshot.exists) {
                          final data = Map<dynamic, dynamic>.from(
                            snapshot.value as Map,
                          );
                          if (data['is_live'] == true) {
                            bool granted =
                                await PermissionService.requestCameraAndMic();
                            if (granted && mounted) {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => LiveVideoRoomPage(
                                    isTeacher: false,
                                    classId: classId,
                                    topic: data['topic'] ?? 'Live Class',
                                    participantId: widget.studentData['key']
                                        ?.toString(),
                                    participantName: widget.studentData['name']
                                        ?.toString(),
                                  ),
                                ),
                              );
                              return;
                            }
                          }
                        }
                        _showNoLiveClass();
                      }
                    },
                  ),
                  _buildBottomBarItem(
                    Icons.person_rounded,
                    'Profile',
                    false,
                    onTap: _showStudentProfile,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBarItem(
    IconData icon,
    String label,
    bool isActive, {
    VoidCallback? onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isActive
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                icon,
                color: isActive
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.8),
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
                color: isActive
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SubjectRecordingsPage extends StatefulWidget {
  final String subjectName;
  final bool isTeacher;
  final String classId;
  final String participantId;
  final String subjectKey;

  const SubjectRecordingsPage({
    super.key,
    required this.subjectName,
    required this.isTeacher,
    required this.classId,
    required this.participantId,
    required this.subjectKey,
  });

  @override
  State<SubjectRecordingsPage> createState() => _SubjectRecordingsPageState();
}

class _SubjectRecordingsPageState extends State<SubjectRecordingsPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedTab = 'lectures';
  int _notesStreamKey = 0; // Increment to force notes stream refresh

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _hasPlayableRecording(Map<dynamic, dynamic> recording) {
    final hasUrl =
        recording['video_url'] != null &&
        recording['video_url'].toString().isNotEmpty;
    final hasBase64 =
        recording['video_base64'] != null &&
        recording['video_base64'].toString().isNotEmpty;
    return hasUrl || hasBase64;
  }

  String? _recordingStatusLabel(Map<dynamic, dynamic> recording) {
    if (_hasPlayableRecording(recording)) return null;

    final status = recording['upload_status']?.toString();
    if (status == 'preparing' || status == 'uploading') {
      return 'Uploading';
    }
    return 'Upload failed';
  }

  IconData _recordingIcon(Map<dynamic, dynamic> recording) {
    if (_hasPlayableRecording(recording)) {
      return Icons.play_circle_fill_rounded;
    }

    final status = recording['upload_status']?.toString();
    if (status == 'preparing' || status == 'uploading') {
      return Icons.cloud_upload_rounded;
    }
    return Icons.cloud_off_rounded;
  }

  String _recordingUnavailableMessage(Map<dynamic, dynamic> recording) {
    final status = recording['upload_status']?.toString();
    if (status == 'preparing' || status == 'uploading') {
      return 'Video is still uploading. Try again shortly.';
    }

    final error = recording['upload_error']?.toString();
    if (error != null && error.isNotEmpty) {
      return 'Video upload failed: $error';
    }

    return 'This recording has no video file available.';
  }

  void _toggleLike(String recordingKey, Map<dynamic, dynamic>? likesMap) {
    final likesRef = FirebaseDatabase.instance
        .ref()
        .child('recorded_classes')
        .child(widget.classId)
        .child(recordingKey)
        .child('likes')
        .child(widget.participantId);

    final isLiked = likesMap != null && likesMap[widget.participantId] == true;

    if (isLiked) {
      likesRef.remove();
    } else {
      likesRef.set(true);
    }
  }

  Future<void> _incrementViews(String recordingKey) async {
    final viewsRef = FirebaseDatabase.instance
        .ref()
        .child('recorded_classes')
        .child(widget.classId)
        .child(recordingKey)
        .child('views');

    await viewsRef.runTransaction((Object? val) {
      final int current = (val as int? ?? 0);
      return Transaction.success(current + 1);
    });
  }

  Future<void> _uploadCustomThumbnail(BuildContext context, String recordingKey) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (pickedFile == null) return;

    // Show loader
    if (!context.mounted) return;
    BuildContext? dialogContext;
    bool dialogClosed = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        if (dialogClosed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ctx.mounted) {
              Navigator.of(ctx).pop();
            }
          });
        }
        return const Center(child: CircularProgressIndicator());
      },
    );

    try {
      final authUid = await FirebaseUploadAuthService.ensureSignedIn();
      if (authUid == null) {
        throw Exception('Firebase authentication failed. Ensure anonymous sign-in is enabled in Firebase Console.');
      }
      final ref = FirebaseStorage.instance
          .ref()
          .child('thumbnails')
          .child(widget.classId)
          .child('$recordingKey.jpg');

      if (kIsWeb) {
        final bytes = await pickedFile.readAsBytes();
        await ref.putData(
          bytes,
          SettableMetadata(contentType: 'image/jpeg'),
        );
      } else {
        final file = File(pickedFile.path);
        await ref.putFile(file);
      }
      final downloadUrl = await ref.getDownloadURL();

      await FirebaseDatabase.instance
          .ref()
          .child('recorded_classes')
          .child(widget.classId)
          .child(recordingKey)
          .update({'thumbnail_url': downloadUrl});

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thumbnail updated successfully!')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload thumbnail: $e')),
        );
      }
    } finally {
      dialogClosed = true;
      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop();
      }
    }
  }



  Future<void> _openNote(BuildContext context, Map<dynamic, dynamic> note) async {
    final fileUrl = note['file_url']?.toString();
    if (fileUrl == null || fileUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File link is empty.')),
      );
      return;
    }

    final isPdf = note['file_type'] == 'pdf';
    if (isPdf) {
      try {
        final uri = Uri.parse(fileUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open PDF link.')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening PDF: $e')),
        );
      }
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NoteImageViewerPage(
            title: note['title'] ?? 'Note Image',
            imageUrl: fileUrl,
          ),
        ),
      );
    }
  }

  Future<void> _deleteNote(BuildContext context, String noteKey, String fileUrl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Note?'),
        content: const Text('This action cannot be undone and will delete the note file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentRed),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (!context.mounted) return;

      BuildContext? dialogContext;
      bool dialogClosed = false;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogContext = ctx;
          if (dialogClosed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
              }
            });
          }
          return const Center(child: CircularProgressIndicator());
        },
      );

      try {
        // Ensure authenticated before any Firebase write
        await FirebaseUploadAuthService.ensureSignedIn();

        if (fileUrl.isNotEmpty) {
          try {
            await FirebaseStorage.instance.refFromURL(fileUrl).delete();
          } catch (_) {}
        }
        await FirebaseDatabase.instance
            .ref()
            .child('subject_notes')
            .child(widget.classId)
            .child(widget.subjectKey)
            .child(noteKey)
            .remove();

        if (context.mounted) {
          setState(() => _notesStreamKey++); // Force notes list refresh
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Note deleted successfully.')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete note: $e')),
          );
        }
      } finally {
        dialogClosed = true;
        if (dialogContext != null && dialogContext!.mounted) {
          Navigator.of(dialogContext!).pop();
        }
      }
    }
  }

  Future<void> _showUploadNoteDialog(BuildContext context) async {
    final titleController = TextEditingController();
    String noteType = 'image';
    PlatformFile? selectedFile;
    bool isUploading = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<void> pickNoteFile() async {
              try {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: noteType == 'pdf'
                      ? ['pdf']
                      : ['png', 'jpg', 'jpeg'],
                );
                if (result != null && result.files.isNotEmpty) {
                  setDialogState(() {
                    selectedFile = result.files.first;
                  });
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error picking file: $e')),
                );
              }
            }

            Future<void> uploadNote() async {
              final title = titleController.text.trim();
              if (title.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a note title.')),
                );
                return;
              }
              if (selectedFile == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please select a file to upload.')),
                );
                return;
              }

              setDialogState(() {
                isUploading = true;
              });

              try {
                final authUid = await FirebaseUploadAuthService.ensureSignedIn();
                if (authUid == null) {
                  throw Exception('Firebase authentication failed. Ensure anonymous sign-in is enabled in Firebase Console.');
                }

                final noteKey = FirebaseDatabase.instance.ref().push().key ?? DateTime.now().millisecondsSinceEpoch.toString();
                final fileExtension = selectedFile!.extension ?? (noteType == 'pdf' ? 'pdf' : 'jpg');
                final ref = FirebaseStorage.instance
                    .ref()
                    .child('notes')
                    .child(widget.classId)
                    .child(widget.subjectKey)
                    .child('$noteKey.$fileExtension');

                if (kIsWeb) {
                  final bytes = selectedFile!.bytes;
                  if (bytes == null) {
                    throw Exception('Could not read file bytes.');
                  }
                  final mimeType = noteType == 'pdf'
                      ? 'application/pdf'
                      : (fileExtension == 'png' ? 'image/png' : 'image/jpeg');
                  await ref.putData(
                    bytes,
                    SettableMetadata(contentType: mimeType),
                  );
                } else {
                  final file = File(selectedFile!.path!);
                  await ref.putFile(file);
                }
                final downloadUrl = await ref.getDownloadURL();

                await FirebaseDatabase.instance
                    .ref()
                    .child('subject_notes')
                    .child(widget.classId)
                    .child(widget.subjectKey)
                    .child(noteKey)
                    .set({
                      'title': title,
                      'file_url': downloadUrl,
                      'file_type': noteType,
                      'uploaded_at': DateTime.now().millisecondsSinceEpoch,
                    });

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(); // Dismiss upload dialog
                }
                if (context.mounted) {
                  setState(() => _notesStreamKey++); // Force notes list refresh
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Note uploaded successfully!')),
                  );
                }
              } catch (e) {
                setDialogState(() {
                  isUploading = false;
                });
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Upload failed: $e'),
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text(
                'Upload Subject Notes',
                style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: AppColors.primaryNavy),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Note Title',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: titleController,
                      enabled: !isUploading,
                      decoration: InputDecoration(
                        hintText: 'e.g., Chapter 1 Formula Sheet',
                        filled: true,
                        fillColor: Colors.grey.withValues(alpha: 0.05),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Note Type',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('Image Note'),
                            selected: noteType == 'image',
                            onSelected: isUploading
                                ? null
                                : (val) {
                                    if (val) {
                                      setDialogState(() {
                                        noteType = 'image';
                                        selectedFile = null;
                                      });
                                    }
                                  },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('PDF Document'),
                            selected: noteType == 'pdf',
                            onSelected: isUploading
                                ? null
                                : (val) {
                                    if (val) {
                                      setDialogState(() {
                                        noteType = 'pdf';
                                        selectedFile = null;
                                      });
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: isUploading ? null : pickNoteFile,
                      icon: const Icon(Icons.attach_file_rounded),
                      label: Text(
                        selectedFile == null ? 'Select File' : 'Change File',
                        style: GoogleFonts.poppins(),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryNavy.withValues(alpha: 0.1),
                        foregroundColor: AppColors.primaryNavy,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    if (selectedFile != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Selected: ${selectedFile!.name}',
                        style: GoogleFonts.poppins(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              actions: isUploading
                  ? [
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(8.0),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    ]
                  : [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton(
                        onPressed: uploadNote,
                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryNavy),
                        child: const Text('Upload', style: TextStyle(color: Colors.white)),
                      ),
                    ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.primaryNavy),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.subjectName,
          style: GoogleFonts.poppins(
            color: AppColors.primaryNavy,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      ),
      floatingActionButton: widget.isTeacher && _selectedTab == 'notes'
          ? FloatingActionButton.extended(
              onPressed: () => _showUploadNoteDialog(context),
              backgroundColor: AppColors.primaryNavy,
              icon: const Icon(Icons.note_add_rounded, color: Colors.white),
              label: Text(
                'Upload Notes',
                style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            )
          : null,
      body: Column(
        children: [
          // Tab Selector
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.cardBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedTab = 'lectures'),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _selectedTab == 'lectures'
                              ? AppColors.primaryNavy
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Lectures',
                          style: GoogleFonts.poppins(
                            color: _selectedTab == 'lectures'
                                ? Colors.white
                                : AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedTab = 'notes'),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _selectedTab == 'notes'
                              ? AppColors.primaryNavy
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Notes',
                          style: GoogleFonts.poppins(
                            color: _selectedTab == 'notes'
                                ? Colors.white
                                : AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
            child: TextField(
              controller: _searchController,
              onChanged: (val) {
                setState(() {
                  _searchQuery = val.trim().toLowerCase();
                });
              },
              decoration: InputDecoration(
                hintText: _selectedTab == 'lectures'
                    ? 'Search by topic...'
                    : 'Search by title...',
                hintStyle: GoogleFonts.poppins(color: AppColors.textLight, fontSize: 14),
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primaryNavy, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppColors.cardBackground,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: const BorderSide(color: AppColors.primaryNavy, width: 1.5),
                ),
              ),
            ),
          ),

          Expanded(
            child: _selectedTab == 'lectures'
                ? FreshStreamBuilder<DatabaseEvent>(
                    streamFactory: () => FirebaseDatabase.instance
                        .ref()
                        .child('recorded_classes')
                        .child(widget.classId)
                        .onValue,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return Center(child: Text('Error: ${snapshot.error}'));
                      }

                      List<Map<dynamic, dynamic>> recordings = [];
                      if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                        final map = Map<dynamic, dynamic>.from(snapshot.data!.snapshot.value as Map);
                        recordings = map.entries.map((e) {
                          return {'key': e.key, ...Map<dynamic, dynamic>.from(e.value)};
                        }).toList();
                      }

                      // Filter by subjectKey
                      recordings = recordings.where((rc) {
                        final rSubId = rc['subject_id']?.toString() ?? '';
                        final targetKey = widget.subjectKey;
                        if (targetKey == 'general' || targetKey.isEmpty) {
                          return rSubId.isEmpty || rSubId == 'general';
                        }
                        return rSubId == targetKey;
                      }).toList();

                      // Filter by search query
                      if (_searchQuery.isNotEmpty) {
                        recordings = recordings.where((rc) {
                          final topic = (rc['topic']?.toString() ?? '').toLowerCase();
                          return topic.contains(_searchQuery);
                        }).toList();
                      }

                      // Sort by date descending
                      recordings.sort((a, b) => (b['date'] as int? ?? 0).compareTo(a['date'] as int? ?? 0));

                      if (recordings.isEmpty) {
                        return Center(
                          child: Text(
                            _searchQuery.isNotEmpty
                                ? 'No matching recordings found.'
                                : 'No recordings in this subject folder yet.',
                            style: GoogleFonts.poppins(color: AppColors.textLight),
                          ),
                        );
                      }

                      return ListView.separated(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 100),
                        itemCount: recordings.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 16),
                        itemBuilder: (context, index) {
                          final rc = recordings[index];
                          final hasPlayable = _hasPlayableRecording(rc);
                          final statusLabel = _recordingStatusLabel(rc);
                          final thumbnailColor = Color(rc['thumbnail_color'] ?? 0xFF3B82F6);

                          // Likes details
                          final likesMap = rc['likes'] is Map ? rc['likes'] as Map : null;
                          final likesCount = likesMap?.length ?? 0;
                          final isLiked = likesMap != null && likesMap[widget.participantId] == true;

                          // Views count
                          final viewsCount = rc['views'] ?? 0;
                          final thumbnailUrl = rc['thumbnail_url']?.toString();

                          return Container(
                            decoration: BoxDecoration(
                              color: AppColors.cardBackground,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.divider),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primaryNavy.withValues(alpha: 0.02),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                  contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                                  leading: GestureDetector(
                                    onTap: widget.isTeacher
                                        ? () => _uploadCustomThumbnail(context, rc['key'])
                                        : null,
                                    child: Stack(
                                      children: [
                                        Container(
                                          width: 60,
                                          height: 60,
                                          decoration: BoxDecoration(
                                            color: thumbnailColor.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(15),
                                          ),
                                          child: thumbnailUrl != null && thumbnailUrl.isNotEmpty
                                              ? ClipRRect(
                                                  borderRadius: BorderRadius.circular(15),
                                                  child: UniversalImage(
                                                    imageUrl: thumbnailUrl,
                                                    fit: BoxFit.cover,
                                                    errorBuilder: (ctx, err, stack) => Icon(
                                                      _recordingIcon(rc),
                                                      color: thumbnailColor,
                                                      size: 28,
                                                    ),
                                                  ),
                                                )
                                              : Icon(
                                                  _recordingIcon(rc),
                                                  color: thumbnailColor,
                                                  size: 28,
                                                ),
                                        ),
                                        if (widget.isTeacher)
                                          Positioned(
                                            right: 0,
                                            bottom: 0,
                                            child: Container(
                                              padding: const EdgeInsets.all(3),
                                              decoration: const BoxDecoration(
                                                color: AppColors.primaryNavy,
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.camera_alt_rounded,
                                                color: Colors.white,
                                                size: 10,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  title: Text(
                                    rc['topic'] ?? 'Recorded Class',
                                    style: GoogleFonts.poppins(
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textPrimary,
                                      fontSize: 16,
                                    ),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Duration: ${rc['duration'] ?? 'N/A'} • Date: ${DateTime.fromMillisecondsSinceEpoch(rc['date'] ?? 0).toString().split(' ')[0]}',
                                          style: GoogleFonts.poppins(
                                            fontSize: 11,
                                            color: AppColors.textLight,
                                          ),
                                        ),
                                        if (statusLabel != null)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 2),
                                            child: Text(
                                              statusLabel,
                                              style: GoogleFonts.poppins(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: AppColors.accentRed,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: AppColors.primaryNavy.withValues(alpha: 0.08),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.play_arrow_rounded, color: AppColors.primaryNavy, size: 22),
                                        ),
                                        onPressed: () async {
                                          if (hasPlayable) {
                                            // Increment views count
                                            await _incrementViews(rc['key']);

                                            final hasUrl =
                                                rc['video_url'] != null &&
                                                rc['video_url'].toString().isNotEmpty;
                                            final hasBase64 =
                                                rc['video_base64'] != null &&
                                                rc['video_base64'].toString().isNotEmpty;
                                            if (context.mounted) {
                                              Navigator.of(context).push(
                                                MaterialPageRoute(
                                                  builder: (_) => VideoPlayerPage(
                                                    videoUrl: hasUrl ? rc['video_url'] : null,
                                                    videoBase64: hasBase64 ? rc['video_base64'] : null,
                                                    mimeType: rc['mime_type']?.toString(),
                                                    title: rc['topic'] ?? 'Recorded Class',
                                                  ),
                                                ),
                                              );
                                            }
                                          } else {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text(_recordingUnavailableMessage(rc))),
                                            );
                                          }
                                        },
                                      ),
                                      if (widget.isTeacher)
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.accentRed),
                                          onPressed: () async {
                                            final confirmed = await showDialog<bool>(
                                              context: context,
                                              builder: (ctx) => AlertDialog(
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                                title: const Text('Delete Recording?'),
                                                content: const Text('This action cannot be undone.'),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () => Navigator.of(ctx).pop(false),
                                                    child: const Text('Cancel'),
                                                  ),
                                                  ElevatedButton(
                                                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentRed),
                                                    onPressed: () => Navigator.of(ctx).pop(true),
                                                    child: const Text('Delete', style: TextStyle(color: Colors.white)),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirmed == true && rc['key'] != null) {
                                              final videoUrl = rc['video_url']?.toString();
                                              if (videoUrl != null && videoUrl.isNotEmpty) {
                                                try {
                                                  await FirebaseStorage.instance.refFromURL(videoUrl).delete();
                                                } catch (_) {}
                                              }
                                              await FirebaseDatabase.instance
                                                  .ref()
                                                  .child('recorded_classes')
                                                  .child(widget.classId)
                                                  .child(rc['key'])
                                                  .remove();
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1, indent: 16, endIndent: 16),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.remove_red_eye_rounded,
                                            color: AppColors.textLight,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '$viewsCount ${viewsCount == 1 ? "view" : "views"}',
                                            style: GoogleFonts.poppins(
                                              fontSize: 12,
                                              color: AppColors.textLight,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                      GestureDetector(
                                        onTap: () => _toggleLike(rc['key'], likesMap),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isLiked
                                                ? AppColors.accentRed.withValues(alpha: 0.1)
                                                : Colors.grey.withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                isLiked ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                                                color: isLiked ? AppColors.accentRed : AppColors.textLight,
                                                size: 16,
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                '$likesCount',
                                                style: GoogleFonts.poppins(
                                                  fontSize: 12,
                                                  color: isLiked ? AppColors.accentRed : AppColors.textLight,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  )
                : FreshStreamBuilder<DatabaseEvent>(
                        key: ValueKey('notes_stream_$_notesStreamKey'),
                        streamFactory: () {
                          final ref = FirebaseDatabase.instance
                              .ref()
                              .child('subject_notes')
                              .child(widget.classId)
                              .child(widget.subjectKey);
                          ref.keepSynced(true);
                          return ref.onValue;
                        },
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          if (snapshot.hasError) {
                            return Center(child: Text('Error: ${snapshot.error}'));
                          }

                          List<Map<dynamic, dynamic>> notesList = [];
                          if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                            final map = Map<dynamic, dynamic>.from(snapshot.data!.snapshot.value as Map);
                            notesList = map.entries.map((e) {
                              return {'key': e.key, ...Map<dynamic, dynamic>.from(e.value)};
                            }).toList();
                          }

                          // Filter notes by search query
                          if (_searchQuery.isNotEmpty) {
                            notesList = notesList.where((note) {
                              final title = (note['title'] ?? '').toString().toLowerCase();
                              return title.contains(_searchQuery);
                            }).toList();
                          }

                          notesList.sort((a, b) => (b['uploaded_at'] as int? ?? 0).compareTo(a['uploaded_at'] as int? ?? 0));

                          if (notesList.isEmpty) {
                            return Center(
                              child: Text(
                                _searchQuery.isNotEmpty
                                    ? 'No matching notes found.'
                                    : 'No notes uploaded for this subject yet.',
                                style: GoogleFonts.poppins(color: AppColors.textLight),
                              ),
                            );
                          }

                          return ListView.separated(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.only(left: 20, right: 20, bottom: 120),
                            itemCount: notesList.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final note = notesList[index];
                              final fileUrl = note['file_url'] ?? '';
                              final date = note['uploaded_at'] != null
                                  ? DateTime.fromMillisecondsSinceEpoch(note['uploaded_at'] as int)
                                      .toString()
                                      .substring(0, 16)
                                  : '';
                              return Container(
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
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  leading: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryNavy.withValues(alpha: 0.1),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.picture_as_pdf_outlined, color: AppColors.primaryNavy, size: 22),
                                  ),
                                  title: Text(
                                    note['title'] ?? 'Untitled Document',
                                    style: GoogleFonts.poppins(
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textPrimary,
                                      fontSize: 15,
                                    ),
                                  ),
                                  subtitle: Text(
                                    'Uploaded: $date',
                                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textLight),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.open_in_new_rounded, color: AppColors.primaryNavy),
                                        onPressed: () => _openNote(context, note),
                                      ),
                                      if (widget.isTeacher)
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.accentRed),
                                          onPressed: () => _deleteNote(context, note['key'], fileUrl),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                  ),
        ],
      ),
    );
  }
}

class CommonClassSubjectsPage extends StatelessWidget {
  final String commonClassName;
  final String commonClassId;
  final Map<dynamic, dynamic> studentData;

  const CommonClassSubjectsPage({
    super.key,
    required this.commonClassName,
    required this.commonClassId,
    required this.studentData,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.primaryNavy),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          commonClassName,
          style: GoogleFonts.poppins(
            color: AppColors.primaryNavy,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: FirebaseDatabase.instance.ref().child('subjects').child(commonClassId).onValue,
        builder: (context, subjectsSnapshot) {
          return StreamBuilder<DatabaseEvent>(
            stream: FirebaseDatabase.instance.ref().child('recorded_classes').child(commonClassId).onValue,
            builder: (context, recordingsSnapshot) {
              if (subjectsSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              List<Map<String, dynamic>> subjectsList = [];
              if (subjectsSnapshot.hasData && subjectsSnapshot.data!.snapshot.value != null) {
                final map = Map<dynamic, dynamic>.from(subjectsSnapshot.data!.snapshot.value as Map);
                final list = map.entries.map((e) => {
                  'key': e.key,
                  ...Map<String, dynamic>.from(e.value)
                }).toList();
                list.sort((a, b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
                subjectsList.addAll(list);
              }

              List<Map<String, dynamic>> recordingsList = [];
              if (recordingsSnapshot.hasData && recordingsSnapshot.data!.snapshot.value != null) {
                final map = Map<dynamic, dynamic>.from(recordingsSnapshot.data!.snapshot.value as Map);
                recordingsList = map.entries
                    .map((e) => Map<String, dynamic>.from(e.value))
                    .toList();
              }

              final Map<String, List<Map<String, dynamic>>> groupedRecordings = {};
              for (var rc in recordingsList) {
                final subId = rc['subject_id']?.toString();
                if (subId != null) {
                  groupedRecordings.putIfAbsent(subId, () => []).add(rc);
                }
              }

              if (subjectsList.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(
                      'No subjects or recorded lectures available yet.',
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        color: AppColors.textLight,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }

              return GridView.builder(
                padding: const EdgeInsets.all(20),
                physics: const BouncingScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 1.1,
                ),
                itemCount: subjectsList.length,
                itemBuilder: (context, index) {
                  final subject = subjectsList[index];
                  final subjectName = subject['name'] ?? 'Unnamed Subject';
                  final subjectKey = subject['key'] ?? '';
                  final subjectRecordings = groupedRecordings[subjectKey] ?? [];
                  final count = subjectRecordings.length;

                  return GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SubjectRecordingsPage(
                            subjectName: subjectName,
                            isTeacher: false,
                            classId: commonClassId,
                            participantId: studentData['key']?.toString() ?? '',
                            subjectKey: subjectKey,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.divider),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryNavy.withValues(alpha: 0.02),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Icon(
                            Icons.folder_rounded,
                            color: Color(0xFFF59E0B),
                            size: 40,
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                subjectName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: AppColors.primaryNavy,
                                ),
                              ),
                              Text(
                                '$count recordings',
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
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
