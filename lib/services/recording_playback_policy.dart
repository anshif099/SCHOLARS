import 'package:flutter/foundation.dart';

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
