import 'dart:typed_data';
import 'web_recording_helper.dart';

WebRecordingHelper getHelper() => StubWebRecordingHelper();

class StubWebRecordingHelper implements WebRecordingHelper {
  @override
  void start(dynamic mediaRecorder, dynamic stream) {
    // No-op on native platforms
  }

  @override
  Future<Uint8List?> stop() async {
    return null;
  }
}
