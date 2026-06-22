import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';

import '../theme/app_theme.dart';

class TeacherRegistrationPage extends StatefulWidget {
  final Map<dynamic, dynamic>? initialData;
  const TeacherRegistrationPage({super.key, this.initialData});

  @override
  State<TeacherRegistrationPage> createState() => _TeacherRegistrationPageState();
}

class _TeacherRegistrationPageState extends State<TeacherRegistrationPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  
  final _courseController = TextEditingController();
  final _classIdController = TextEditingController();
  final _batchController = TextEditingController();
  final _fromYearController = TextEditingController();
  final _toYearController = TextEditingController();

  bool _isLoading = false;
  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      final data = widget.initialData!;
      _courseController.text = data['course'] ?? '';
      _classIdController.text = data['class_id'] ?? '';
      final batch = data['batch'] as String? ?? '';
      if (batch.contains(' - ')) {
        final parts = batch.split(' - ');
        _fromYearController.text = parts[0];
        _toYearController.text = parts[1];
      }
    } else {
      // Automatically generate a Class ID
      _classIdController.text = 'CLS-${Random().nextInt(9000) + 1000}';
    }

    _animController = AnimationController(
       duration: const Duration(milliseconds: 600),
       vsync: this,
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward();
  }
  @override
  void dispose() {
    _courseController.dispose();
    _classIdController.dispose();
    _batchController.dispose();
    _fromYearController.dispose();
    _toYearController.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isLoading = true);

    try {
      final dbRef = FirebaseDatabase.instance.ref().child('teachers');
      final isUpdating = widget.initialData != null;
      
      if (isUpdating) {
        final key = widget.initialData!['key'];
        await dbRef.child(key).update({
          'course': _courseController.text.trim(),
          'batch': '${_fromYearController.text} - ${_toYearController.text}',
        });
      } else {
        final newTeacherRef = dbRef.push();
        await newTeacherRef.set({
          'id': newTeacherRef.key,
          'course': _courseController.text.trim(),
          'batch': '${_fromYearController.text} - ${_toYearController.text}',
          'class_id': _classIdController.text,
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
                isUpdating ? 'Class updated successfully!' : 'Class registered successfully!',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF10B981), // Emerald Green
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to register: $e'),
          backgroundColor: AppColors.accentRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top Bar ──
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
                            color: AppColors.primaryNavy.withValues(alpha: 0.04),
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
                    widget.initialData != null ? 'Edit Class' : 'Add Class',
                    style: GoogleFonts.poppins(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),

            // ── Form Content ──
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: SlideTransition(
                    position: _slideAnim,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── Header Icon & Text ──
                          Center(
                            child: Column(
                              children: [
                                Container(
                                  width: 70,
                                  height: 70,
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryNavy.withValues(alpha: 0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.class_rounded,
                                    size: 32,
                                    color: AppColors.primaryNavy,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  widget.initialData != null ? 'Edit Class Details' : 'Class Registration',
                                  style: GoogleFonts.poppins(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primaryNavy,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.initialData != null ? 'Update the details for this class' : 'Enter details to register a new class',
                                  style: GoogleFonts.poppins(
                                    fontSize: 13,
                                    color: AppColors.textLight,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          
                          const SizedBox(height: 40),

                          // ── Fields ──
                          _buildLabel('Class / Course'),
                          const SizedBox(height: 8),
                          _buildTextField(
                            controller: _courseController,
                            hint: 'e.g., Mathematics 101',
                            icon: Icons.menu_book_rounded,
                            validator: (val) => val == null || val.trim().isEmpty ? 'Enter class/course name' : null,
                          ),
                          const SizedBox(height: 20),
                          _buildLabel('Select Batch Year Range'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => _showYearPicker(context, _fromYearController),
                                  child: AbsorbPointer(
                                    child: _buildTextField(
                                      controller: _fromYearController,
                                      hint: 'From Year',
                                      icon: Icons.calendar_today_rounded,
                                      validator: (val) => val == null || val.isEmpty ? 'Required' : null,
                                    ),
                                  ),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: Text('—', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textLight)),
                              ),
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => _showYearPicker(context, _toYearController),
                                  child: AbsorbPointer(
                                    child: _buildTextField(
                                      controller: _toYearController,
                                      hint: 'To Year',
                                      icon: Icons.calendar_today_rounded,
                                      validator: (val) => val == null || val.isEmpty ? 'Required' : null,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          _buildLabel('Class ID (Auto-generated)'),
                          const SizedBox(height: 8),
                          _buildTextField(
                            controller: _classIdController,
                            hint: 'Generates automatically',
                            icon: Icons.badge_outlined,
                            readOnly: true,
                          ),

                          const SizedBox(height: 40),

                          // ── Submit Button ──
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _handleSubmit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryNavy,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: AppColors.primaryNavy.withValues(alpha: 0.6),
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
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                      ),
                                    )
                                  : Text(
                                      widget.initialData != null ? 'Update Class' : 'Register Class',
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

  void _showYearPicker(BuildContext context, TextEditingController controller) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("Select Year", style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 300,
            height: 300,
            child: YearPicker(
              firstDate: DateTime(DateTime.now().year - 100, 1),
              lastDate: DateTime(DateTime.now().year + 100, 1),
              selectedDate: DateTime.now(),
              onChanged: (DateTime dateTime) {
                controller.text = dateTime.year.toString();
                Navigator.pop(context);
              },
            ),
          ),
        );
      },
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
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: keyboardType,
      style: GoogleFonts.poppins(
        fontSize: 15,
        color: readOnly ? AppColors.textLight : AppColors.textPrimary,
        fontWeight: readOnly ? FontWeight.w600 : FontWeight.w400,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.poppins(
          fontSize: 14,
          color: AppColors.textLight.withValues(alpha: 0.6),
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 16, right: 12),
          child: Icon(
            icon, 
            size: 20, 
            color: readOnly ? AppColors.textLight.withValues(alpha: 0.7) : AppColors.textLight,
          ),
        ),
        filled: true,
        fillColor: readOnly ? AppColors.divider.withValues(alpha: 0.3) : AppColors.cardBackground,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: readOnly ? AppColors.divider : AppColors.primaryNavy, 
            width: readOnly ? 1.0 : 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.accentRed),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.accentRed, width: 1.5),
        ),
        errorStyle: GoogleFonts.poppins(
          fontSize: 12,
          color: AppColors.accentRed,
        ),
      ),
      validator: validator,
    );
  }
}
