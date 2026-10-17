import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<void> prepareRecordedMediaAudio() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await const MethodChannel(
      'com.academy.scholars/audio_output',
    ).invokeMethod<void>('prepareMediaPlayback');
  } catch (error) {
    debugPrint('Could not restore Android media audio: $error');
  }
}
