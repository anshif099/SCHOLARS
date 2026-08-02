import 'web_recording_helper.dart';

WebRecordingHelper getHelper() => StubWebRecordingHelper();

class StubWebRecordingHelper implements WebRecordingHelper {
  @override
  String get recordedMimeType => 'video/mp4';

  @override
  int get recordedSizeBytes => 0;

  @override
  void start(
    dynamic mediaRecorder,
    dynamic stream, {
    List<dynamic>? remoteStreams,
  }) {
    // No-op on native platforms
  }

  @override
  void addRemoteStream(dynamic stream) {
    // No-op on native platforms
  }

  @override
  Future<dynamic> stop() async {
    return null;
  }
}
