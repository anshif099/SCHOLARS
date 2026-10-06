import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Disable this gate after management's payment has been confirmed.
class ManagementPaymentGate extends StatelessWidget {
  const ManagementPaymentGate({super.key, required this.child});

  static const bool paymentRequired = true;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!paymentRequired) {
      return child;
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            const ModalBarrier(dismissible: false, color: Colors.black54),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  child: AlertDialog(
                    icon: const Icon(
                      Icons.lock_outline_rounded,
                      color: AppColors.accentRed,
                      size: 40,
                    ),
                    title: const Text(
                      'Payment required',
                      textAlign: TextAlign.center,
                    ),
                    content: const Text(
                      'Your management has not paid the mandatory database '
                      'storage fee of Rs. 717.63.\n\n'
                      'App access is suspended. Please arrange payment of '
                      'Rs. 1,000 to continue using the app.\n\n'
                      'Please contact your management.',
                      textAlign: TextAlign.center,
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
