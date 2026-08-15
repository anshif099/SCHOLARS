import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraMicAccessResult {
  const CameraMicAccessResult({
    required this.granted,
    this.preparedStream,
    this.errorMessage,
    this.permanentlyDenied = false,
  });

  final bool granted;
  final MediaStream? preparedStream;
  final String? errorMessage;
  final bool permanentlyDenied;
}

class PermissionService {
  static Map<String, dynamic> get _preferredWebAudioConstraints =>
      <String, dynamic>{
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'channelCount': 1,
      };

  static Future<bool> requestCameraAndMic() async {
    if (kIsWeb) return true;
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    return statuses[Permission.camera] == PermissionStatus.granted &&
        statuses[Permission.microphone] == PermissionStatus.granted;
  }

  /// Requests media access while still inside the user's Join/Go Live tap.
  /// Safari may reject getUserMedia when it is first called after navigation,
  /// so web callers pass this prepared stream into the live room.
  static Future<CameraMicAccessResult> prepareCameraAndMicForCall() async {
    if (kIsWeb) {
      try {
        final stream = await _getWebUserMediaWithFallback();
        return CameraMicAccessResult(granted: true, preparedStream: stream);
      } catch (error) {
        return CameraMicAccessResult(
          granted: false,
          errorMessage: error.toString(),
        );
      }
    }

    final statuses = await <Permission>[
      Permission.camera,
      Permission.microphone,
    ].request();
    final cameraStatus = statuses[Permission.camera];
    final microphoneStatus = statuses[Permission.microphone];
    final granted =
        cameraStatus == PermissionStatus.granted &&
        microphoneStatus == PermissionStatus.granted;
    return CameraMicAccessResult(
      granted: granted,
      permanentlyDenied:
          cameraStatus == PermissionStatus.permanentlyDenied ||
          microphoneStatus == PermissionStatus.permanentlyDenied,
    );
  }

  static void stopPreparedStream(MediaStream? stream) {
    for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
  }

  static Future<void> requestAllPermissions() async {
    if (kIsWeb) return;
    await [
      Permission.camera,
      Permission.microphone,
      Permission.notification,
    ].request();
  }

  static Future<MediaStream> _getWebUserMediaWithFallback() async {
    // Attempt 1: Ideal resolution and frame rate
    try {
      return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': _preferredWebAudioConstraints,
        'video': <String, dynamic>{
          'width': <String, dynamic>{'ideal': 640},
          'height': <String, dynamic>{'ideal': 360},
          'frameRate': <String, dynamic>{'ideal': 30},
          'facingMode': 'user',
        },
      });
    } catch (_) {}

    // Attempt 2: Simplified facingMode constraint (iOS Safari compatible)
    try {
      return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': _preferredWebAudioConstraints,
        'video': <String, dynamic>{'facingMode': 'user'},
      });
    } catch (_) {}

    // Attempt 3: Basic audio + video
    return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': true,
    });
  }
}
