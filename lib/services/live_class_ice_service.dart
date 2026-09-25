import 'package:cloud_functions/cloud_functions.dart';

import 'firebase_upload_auth_service.dart';
import 'webrtc_ice_server_config.dart';

class LiveClassIceService {
  static Future<List<Map<String, dynamic>>> load({
    required String classId,
    required String participantId,
  }) async {
    final builtInServers = buildWebRtcIceServers();
    if (builtInServers.length > 1) return builtInServers;

    final uid = await FirebaseUploadAuthService.ensureSignedIn();
    if (uid == null) {
      throw StateError('Sign in is required to connect live video.');
    }

    final result = await FirebaseFunctions.instance
        .httpsCallable('getLiveClassIceServers')
        .call(<String, dynamic>{
          'classId': classId,
          'participantId': participantId,
        });
    final data = Map<String, dynamic>.from(result.data as Map);
    final relayServers = (data['iceServers'] as List)
        .map((server) => Map<String, dynamic>.from(server as Map))
        .toList(growable: false);
    if (!relayServers.any(
      (server) =>
          server['username']?.toString().isNotEmpty == true &&
          server['credential']?.toString().isNotEmpty == true,
    )) {
      throw StateError('Video relay credentials are unavailable.');
    }
    return <Map<String, dynamic>>[...builtInServers, ...relayServers];
  }
}
