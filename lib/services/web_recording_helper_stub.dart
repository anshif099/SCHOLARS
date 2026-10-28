import 'web_recording_helper.dart';

WebRecordingHelper getHelper() => StubWebRecordingHelper();

class StubWebRecordingHelper implements WebRecordingHelper {
  @override
  Future<void> setPaused(bool paused) async {}

  @override
  String get recordedMimeType => 'video/mp4';

  @override
  int get recordedSizeBytes => 0;

  @override
  Future<void> start(
    dynamic mediaRecorder,
    dynamic stream, {
    List<dynamic>? remoteStreams,
  }) {
    // No-op on native platforms
    return Future<void>.value();
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
