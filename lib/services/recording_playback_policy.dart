import 'package:flutter/foundation.dart';

/// Used only after checking playable media and active upload/preparation.
/// A missing URL or an old progress timestamp does not prove transfer failure.
String recordingUnavailableStatus(Map recording) {
  return switch (recording['upload_status']?.toString()) {
    'empty_file' => 'Recording file was empty',
    'finalization_failed' => 'Recording could not be finalized',
    'auth_failed' => 'Upload sign-in failed',
    'upload_failed' || 'failed' => 'Upload failed',
    'preparing' ||
    'uploading' ||
    'retrying' => 'Upload interrupted — not completed',
    _ => 'Video unavailable',
  };
}

bool needsIOSRecordingConversion(Map recording, {bool? isIOSWeb}) {
  final runsOnIOSWeb =
      isIOSWeb ?? (kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  if (!runsOnIOSWeb) return false;

  final mime = recording['mime_type']?.toString().toLowerCase() ?? '';
  final url = recording['video_url']?.toString().toLowerCase() ?? '';
  return mime.contains('webm') || url.contains('.webm');
}

bool isIOSRecordingPreparationPending(Map recording, {bool? isIOSWeb}) {
  final status = recording['compatibility_status']?.toString();
  final isPending = status == 'waiting' || status == 'converting';
  return isPending &&
      needsIOSRecordingConversion(recording, isIOSWeb: isIOSWeb);
}
