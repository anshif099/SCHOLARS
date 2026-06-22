import 'dart:typed_data';

import 'web_recording_helper_stub.dart'
    if (dart.library.html) 'web_recording_helper_web.dart';

abstract class WebRecordingHelper {
  factory WebRecordingHelper() => getHelper();

  void start(
    dynamic mediaRecorder,
    dynamic stream, {
    List<dynamic>? remoteStreams,
  });

  void addRemoteStream(dynamic stream);

  Future<Uint8List?> stop();
}
