const List<String> _defaultWebRtcStunUrls = <String>[
  'stun:stun.l.google.com:19302',
  'stun:stun1.l.google.com:19302',
  'stun:stun2.l.google.com:19302',
  'stun:stun3.l.google.com:19302',
  'stun:stun4.l.google.com:19302',
];

/// Builds the ICE server list used by live classes.
///
/// TURN values are supplied at build time so deployment-specific credentials
/// are never committed to source control. Multiple URLs can be separated with
/// commas, for example UDP, TCP, and TLS endpoints for the same TURN service.
List<Map<String, dynamic>> buildWebRtcIceServers({
  String turnUrls = const String.fromEnvironment('WEBRTC_TURN_URLS'),
  String turnUsername = const String.fromEnvironment('WEBRTC_TURN_USERNAME'),
  String turnCredential = const String.fromEnvironment(
    'WEBRTC_TURN_CREDENTIAL',
  ),
}) {
  final servers = <Map<String, dynamic>>[
    <String, dynamic>{'urls': _defaultWebRtcStunUrls},
  ];
  final urls = turnUrls
      .split(',')
      .map((url) => url.trim())
      .where((url) => url.startsWith('turn:') || url.startsWith('turns:'))
      .toSet()
      .toList(growable: false);
  final username = turnUsername.trim();
  final credential = turnCredential.trim();

  if (urls.isNotEmpty && username.isNotEmpty && credential.isNotEmpty) {
    servers.add(<String, dynamic>{
      'urls': urls,
      'username': username,
      'credential': credential,
    });
  }

  return servers;
}
