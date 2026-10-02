import 'package:cloud_functions/cloud_functions.dart';

import 'firebase_upload_auth_service.dart';
import 'webrtc_ice_server_config.dart';

class LiveClassIceService {
  // The same Firebase callable is reachable through its Cloud Run URL. Some
  // networks cannot reach the cloudfunctions.net frontend at all.
  static const relayCallableUrl = String.fromEnvironment(
    'WEBRTC_RELAY_CALLABLE_URL',
    defaultValue: 'https://getliveclassiceservers-gst2citolq-uc.a.run.app',
  );

  static Future<List<Map<String, dynamic>>> load({
    required String classId,
    required String participantId,
  }) async {
    final builtInServers = buildWebRtcIceServers();
    if (builtInServers.length > 1) return builtInServers;

    final uid = await FirebaseUploadAuthService.ensureSignedIn().timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw StateError('Video relay sign-in timed out.'),
    );
    if (uid == null) {
      throw StateError('Sign in is required to connect live video.');
    }

    final result = await FirebaseFunctions.instance
        .httpsCallableFromUrl(
          relayCallableUrl,
          options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
        )
        .call(<String, dynamic>{
          'classId': classId,
          'participantId': participantId,
        })
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw StateError('Video relay connection timed out.'),
        );
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
