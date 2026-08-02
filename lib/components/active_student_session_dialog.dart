import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/student_session_service.dart';
import '../theme/app_theme.dart';

Future<void> showActiveStudentSessionDialog(
  BuildContext context,
  StudentActiveSession? session,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      icon: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: AppColors.accentRed.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.devices_rounded,
          color: AppColors.accentRed,
          size: 30,
        ),
      ),
      title: Text(
        'Already logged in',
        textAlign: TextAlign.center,
        style: GoogleFonts.poppins(
          fontWeight: FontWeight.w700,
          color: AppColors.primaryNavy,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This Student ID is active on another device. Log out from that device before signing in here.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(
                children: [
                  _DetailRow(
                    icon: Icons.devices_other_rounded,
                    label: 'Device',
                    value: session?.deviceName ?? 'Another device',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.language_rounded,
                    label: 'Login type',
                    value: session?.deviceType ?? 'Web / app',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.memory_rounded,
                    label: 'Platform',
                    value: session?.platform ?? 'Unknown',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.schedule_rounded,
                    label: 'Logged in',
                    value: _formatTimestamp(session?.loginAt),
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.update_rounded,
                    label: 'Last active',
                    value: _formatTimestamp(session?.lastActive),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryNavy,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            child: Text(
              'OK',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    ),
  );
}

String _formatTimestamp(int? milliseconds) {
  if (milliseconds == null) return 'Unknown';
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  final hour = time.hour == 0
      ? 12
      : (time.hour > 12 ? time.hour - 12 : time.hour);
  final minute = time.minute.toString().padLeft(2, '0');
  final period = time.hour >= 12 ? 'PM' : 'AM';
  return '${time.day}/${time.month}/${time.year}, $hour:$minute $period';
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: AppColors.primaryNavy),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.textLight,
                ),
              ),
              Text(
                value,
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
