import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';

import '../theme/app_theme.dart';

class TeacherItem {
  final String key;
  final String name;
  final String classId;
  final String course;
  final String batch;

  TeacherItem({
    required this.key,
    required this.name,
    required this.classId,
    required this.course,
    required this.batch,
  });
}

class StudentRegistrationPage extends StatefulWidget {
  final Map<dynamic, dynamic>? initialData;
  final Map<dynamic, dynamic>? forcedTeacherData;
  const StudentRegistrationPage({
    super.key,
    this.initialData,
    this.forcedTeacherData,
  });

  @override
  State<StudentRegistrationPage> createState() =>
      _StudentRegistrationPageState();
}

class _StudentRegistrationPageState extends State<StudentRegistrationPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _classController = TextEditingController();
  final _batchController = TextEditingController();
  final _loginIdController = TextEditingController();

  bool _isLoading = false;
  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  List<TeacherItem> _teachersList = [];
  TeacherItem? _selectedTeacher;
  bool _isLoadingTeachers = true;

  @override
  void initState() {
    super.initState();
    if (widget.forcedTeacherData != null) {
      final t = widget.forcedTeacherData!;
      _selectedTeacher = TeacherItem(
        key: t['key'] ?? t['id'] ?? '',
        name: t['name'] ?? 'Unknown',
        classId: t['class_id'] ?? '',
        course: t['course'] ?? '',
        batch: t['batch'] ?? 'Not Assigned',
      );
      _classController.text = _selectedTeacher!.classId;
      _batchController.text = _selectedTeacher!.batch;
      _isLoadingTeachers = false;
    } else {
      _fetchTeachers();
    }

    if (widget.initialData != null) {
      final data = widget.initialData!;
      _nameController.text = data['name'] ?? '';
      _mobileController.text = data['mobile'] ?? '';
      _classController.text = data['class_id'] ?? '';
      _batchController.text = data['batch'] ?? '';
      _loginIdController.text = data['login_id'] ?? '';
    } else {
      _loginIdController.text = 'STD-${Random().nextInt(90000) + 10000}';
    }

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

  Future<void> _fetchTeachers() async {
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref()
          .child('teachers')
          .get();
      if (snapshot.value != null) {
        final map = Map<dynamic, dynamic>.from(snapshot.value as Map);
        final list = map.entries.map((e) {
          final data = Map<String, dynamic>.from(e.value);
          return TeacherItem(
            key: e.key,
            name: data['name'] ?? 'Unknown',
            classId: data['class_id'] ?? '',
            course: data['course'] ?? '',
            batch: data['batch'] ?? 'Not Assigned',
          );
        }).toList();

        if (mounted) {
          setState(() {
            _teachersList = list;
            _isLoadingTeachers = false;

            // If editing, pre-select teacher if matched by class_id or stored teacher_id
            if (widget.initialData != null) {
              final storedTeacherId = widget.initialData!['teacher_id'];
              try {
                _selectedTeacher = _teachersList.firstWhere(
                  (t) => t.key == storedTeacherId,
                );
                if (_selectedTeacher != null) {
                  _batchController.text = _selectedTeacher!.batch;
                }
              } catch (_) {}
            }
          });
        }
      } else {
        if (mounted) setState(() => _isLoadingTeachers = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingTeachers = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _mobileController.dispose();
    _classController.dispose();
    _batchController.dispose();
    _loginIdController.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedTeacher == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select a class/course first.'),
          backgroundColor: AppColors.accentRed,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final dbRef = FirebaseDatabase.instance.ref().child('students');
      final isUpdating = widget.initialData != null;

      if (isUpdating) {
        final key = widget.initialData!['key'];
        await dbRef.child(key).update({
          'name': _nameController.text.trim(),
          'mobile': _mobileController.text.trim(),
          'class_id': _classController.text.trim(),
          'batch': _batchController.text.trim(),
          'teacher_id': _selectedTeacher!.key,
          'teacher_name': _selectedTeacher!.name,
        });
      } else {
        final newStudentRef = dbRef.push();
        await newStudentRef.set({
          'key': newStudentRef.key,
          'name': _nameController.text.trim(),
          'mobile': _mobileController.text.trim(),
          'class_id': _classController.text.trim(),
          'batch': _batchController.text.trim(),
          'teacher_id': _selectedTeacher!.key,
          'teacher_name': _selectedTeacher!.name,
          'login_id': _normalizeLoginId(_loginIdController.text),
          'created_at': ServerValue.timestamp,
        });
      }

      if (!mounted) return;
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 12),
              Text(
                isUpdating
                    ? 'Student updated successfully!'
                    : 'Student registered successfully!',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );

      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save student: $e'),
          backgroundColor: AppColors.accentRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.poppins(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool readOnly = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: keyboardType,
      style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.poppins(
          color: AppColors.textLight,
          fontSize: 14,
        ),
        prefixIcon: Icon(
          icon,
          color: AppColors.primaryNavy.withValues(alpha: 0.6),
          size: 20,
        ),
        filled: true,
        fillColor: readOnly
            ? AppColors.primaryNavy.withValues(alpha: 0.05)
            : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primaryNavy, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accentRed),
        ),
      ),
      validator: validator,
    );
  }

  String _normalizeLoginId(String value) {
    return value
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2212]'), '-')
        .replaceAll(RegExp(r'\s+'), '');
  }

  @override
  Widget build(BuildContext context) {
    final isUpdating = widget.initialData != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.divider),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryNavy.withValues(
                              alpha: 0.04,
                            ),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                        color: AppColors.primaryNavy,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    isUpdating ? 'Edit Student' : 'Add Student',
                    style: GoogleFonts.poppins(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _isLoadingTeachers
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 20,
                      ),
                      child: FadeTransition(
                        opacity: _fadeAnim,
                        child: SlideTransition(
                          position: _slideAnim,
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Center(
                                  child: Column(
                                    children: [
                                      Container(
                                        width: 70,
                                        height: 70,
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryNavy
                                              .withValues(alpha: 0.1),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.person_add_alt_1_rounded,
                                          size: 32,
                                          color: AppColors.primaryNavy,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        isUpdating
                                            ? 'Edit Student Details'
                                            : 'Student Registration',
                                        style: GoogleFonts.poppins(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.primaryNavy,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        isUpdating
                                            ? 'Update the details for this student'
                                            : 'Enter details to register a new student',
                                        style: GoogleFonts.poppins(
                                          fontSize: 13,
                                          color: AppColors.textLight,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 40),

                                if (widget.forcedTeacherData == null) ...[
                                  _buildLabel('Select Class / Course'),
                                  const SizedBox(height: 8),
                                  // Searchable Dropdown using Autocomplete combined with a nice TextField style
                                  LayoutBuilder(
                                    builder: (context, constraints) {
                                      return Autocomplete<TeacherItem>(
                                        initialValue: TextEditingValue(
                                          text: _selectedTeacher != null
                                              ? (_selectedTeacher!.name == 'Unknown' || _selectedTeacher!.name.isEmpty
                                                  ? _selectedTeacher!.course
                                                  : '${_selectedTeacher!.course} (${_selectedTeacher!.name})')
                                              : '',
                                        ),
                                        displayStringForOption: (item) =>
                                            (item.name == 'Unknown' || item.name.isEmpty)
                                                ? item.course
                                                : '${item.course} (${item.name})',
                                        optionsBuilder:
                                            (
                                              TextEditingValue textEditingValue,
                                            ) {
                                              if (textEditingValue
                                                  .text
                                                  .isEmpty) {
                                                return _teachersList;
                                              }
                                              return _teachersList.where(
                                                (t) =>
                                                    t.name
                                                        .toLowerCase()
                                                        .contains(
                                                          textEditingValue.text
                                                              .toLowerCase(),
                                                        ) ||
                                                    t.course
                                                        .toLowerCase()
                                                        .contains(
                                                          textEditingValue.text
                                                              .toLowerCase(),
                                                        ) ||
                                                    t.classId
                                                        .toLowerCase()
                                                        .contains(
                                                          textEditingValue.text
                                                              .toLowerCase(),
                                                        ),
                                              );
                                            },
                                        onSelected: (TeacherItem selection) {
                                          setState(() {
                                            _selectedTeacher = selection;
                                            _classController.text =
                                                selection.classId;
                                            _batchController.text =
                                                selection.batch;
                                          });
                                          // Clear focus to dismiss keyboard
                                          FocusScope.of(context).unfocus();
                                        },
                                        fieldViewBuilder:
                                            (
                                              context,
                                              textEditingController,
                                              focusNode,
                                              onFieldSubmitted,
                                            ) {
                                              return TextFormField(
                                                controller:
                                                    textEditingController,
                                                focusNode: focusNode,
                                                decoration: InputDecoration(
                                                  hintText:
                                                      'Search by class/course name or teacher...',
                                                  hintStyle:
                                                      GoogleFonts.poppins(
                                                        color:
                                                            AppColors.textLight,
                                                        fontSize: 14,
                                                      ),
                                                  prefixIcon: const Icon(
                                                    Icons.search_rounded,
                                                    color:
                                                        AppColors.primaryNavy,
                                                    size: 20,
                                                  ),
                                                  suffixIcon: const Icon(
                                                    Icons
                                                        .arrow_drop_down_rounded,
                                                  ),
                                                  filled: true,
                                                  fillColor: Colors.white,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 16,
                                                      ),
                                                  border: OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                    borderSide: BorderSide(
                                                      color: AppColors.divider,
                                                    ),
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              12,
                                                            ),
                                                        borderSide: BorderSide(
                                                          color:
                                                              AppColors.divider,
                                                        ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              12,
                                                            ),
                                                        borderSide:
                                                            const BorderSide(
                                                              color: AppColors
                                                                  .primaryNavy,
                                                              width: 2,
                                                            ),
                                                      ),
                                                ),
                                                validator: (v) =>
                                                    _selectedTeacher == null
                                                    ? 'Please select a class/course'
                                                    : null,
                                              );
                                            },
                                        optionsViewBuilder: (context, onSelected, options) {
                                          return Align(
                                            alignment: Alignment.topLeft,
                                            child: Material(
                                              elevation: 4,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: Container(
                                                width: constraints.maxWidth,
                                                constraints:
                                                    const BoxConstraints(
                                                      maxHeight: 200,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  border: Border.all(
                                                    color: AppColors.divider,
                                                  ),
                                                ),
                                                child: ListView.builder(
                                                  padding: EdgeInsets.zero,
                                                  itemCount: options.length,
                                                  itemBuilder:
                                                      (
                                                        BuildContext context,
                                                        int index,
                                                      ) {
                                                        final option = options
                                                            .elementAt(index);
                                                        return ListTile(
                                                          title: Text(
                                                            option.course,
                                                            style:
                                                                GoogleFonts.poppins(
                                                                  fontSize: 14,
                                                                  fontWeight: FontWeight.w600,
                                                                ),
                                                          ),
                                                          subtitle: Text(
                                                            (option.name == 'Unknown' || option.name.isEmpty)
                                                                ? 'Class ID: ${option.classId}'
                                                                : 'Teacher: ${option.name} • Class ID: ${option.classId}',
                                                            style: GoogleFonts.poppins(
                                                              fontSize: 12,
                                                              color: AppColors
                                                                  .textLight,
                                                            ),
                                                          ),
                                                          onTap: () {
                                                            onSelected(option);
                                                          },
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

                                  const SizedBox(height: 20),
                                ],

                                _buildLabel('Class ID (Auto-filled)'),
                                const SizedBox(height: 8),
                                _buildTextField(
                                  controller: _classController,
                                  hint: 'Select a class/course to get class ID',
                                  icon: Icons.meeting_room_outlined,
                                  readOnly: true,
                                  validator: (val) =>
                                      val == null || val.trim().isEmpty
                                      ? 'Class ID is required'
                                      : null,
                                ),

                                const SizedBox(height: 20),

                                _buildLabel('Batch Range (Auto-filled)'),
                                const SizedBox(height: 8),
                                _buildTextField(
                                  controller: _batchController,
                                  hint: 'Select a class/course to get batch range',
                                  icon: Icons.date_range_rounded,
                                  readOnly: true,
                                  validator: (val) =>
                                      val == null || val.trim().isEmpty
                                      ? 'Batch range is required'
                                      : null,
                                ),

                                const SizedBox(height: 20),

                                _buildLabel('Student Full Name'),
                                const SizedBox(height: 8),
                                _buildTextField(
                                  controller: _nameController,
                                  hint: 'e.g., Jane Smith',
                                  icon: Icons.person_outline_rounded,
                                  validator: (val) =>
                                      val == null || val.trim().isEmpty
                                      ? 'Enter student name'
                                      : null,
                                ),

                                const SizedBox(height: 20),

                                _buildLabel('Mobile Number'),
                                const SizedBox(height: 8),
                                _buildTextField(
                                  controller: _mobileController,
                                  hint: 'e.g., +1 234 567 8900',
                                  icon: Icons.phone_outlined,
                                  keyboardType: TextInputType.phone,
                                  validator: (val) =>
                                      val == null || val.trim().isEmpty
                                      ? 'Enter mobile number'
                                      : null,
                                ),

                                const SizedBox(height: 20),

                                _buildLabel('Login ID (Auto-generated)'),
                                const SizedBox(height: 8),
                                _buildTextField(
                                  controller: _loginIdController,
                                  hint: 'Generates automatically',
                                  icon: Icons.badge_outlined,
                                  readOnly: true,
                                ),

                                const SizedBox(height: 40),

                                SizedBox(
                                  width: double.infinity,
                                  height: 54,
                                  child: ElevatedButton(
                                    onPressed: _isLoading
                                        ? null
                                        : _handleSubmit,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primaryNavy,
                                      foregroundColor: Colors.white,
                                      disabledBackgroundColor: AppColors
                                          .primaryNavy
                                          .withValues(alpha: 0.6),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      elevation: 0,
                                    ),
                                    child: _isLoading
                                        ? const SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    Colors.white,
                                                  ),
                                            ),
                                          )
                                        : Text(
                                            isUpdating
                                                ? 'Update Student'
                                                : 'Register Student',
                                            style: GoogleFonts.poppins(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                  ),
                                ),

                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
