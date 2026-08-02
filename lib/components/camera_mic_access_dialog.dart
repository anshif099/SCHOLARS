import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/permission_service.dart';
import '../theme/app_theme.dart';

Future<CameraMicAccessResult?> requestCameraMicAccessForCall(
  BuildContext context,
) async {
  final initialResult = await PermissionService.prepareCameraAndMicForCall();
  if (initialResult.granted || !context.mounted) {
    return initialResult.granted ? initialResult : null;
  }

  var isRetrying = false;
  var lastResult = initialResult;
  return showDialog<CameraMicAccessResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final isIphoneWeb =
              kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Row(
              children: [
                Icon(Icons.camera_alt_rounded, color: AppColors.primaryNavy),
                SizedBox(width: 10),
                Expanded(child: Text('Allow camera and microphone')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Both permissions are required to attend a live class.',
                ),
                const SizedBox(height: 12),
                Text(
                  isIphoneWeb
                      ? 'On iPhone Safari: tap the page settings icon in the address bar, open Website Settings, set Camera and Microphone to Allow, then tap Try again.'
                      : kIsWeb
                      ? 'Open this site’s permissions from the address bar, allow Camera and Microphone, then tap Try again.'
                      : lastResult.permanentlyDenied
                      ? 'Camera or microphone access is blocked in system settings. Enable both permissions for Scholars Academy, then tap Try again.'
                      : 'Allow Camera and Microphone in the permission prompts, then tap Try again.',
                  style: const TextStyle(color: Colors.black87, height: 1.4),
                ),
                if (isRetrying) ...[
                  const SizedBox(height: 18),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isRetrying
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: isRetrying
                    ? null
                    : () async {
                        setDialogState(() => isRetrying = true);
                        // This request starts directly inside the Retry tap,
                        // which is required by Safari's user-activation policy.
                        final retryResult =
                            await PermissionService.prepareCameraAndMicForCall();
                        if (!dialogContext.mounted) {
                          PermissionService.stopPreparedStream(
                            retryResult.preparedStream,
                          );
                          return;
                        }
                        if (retryResult.granted) {
                          Navigator.of(dialogContext).pop(retryResult);
                          return;
                        }
                        setDialogState(() {
                          lastResult = retryResult;
                          isRetrying = false;
                        });
                      },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          );
        },
      );
    },
  );
}
