import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/services/webrtc_ice_server_config.dart';

void main() {
  test('uses STUN without exposing an incomplete TURN configuration', () {
    final servers = buildWebRtcIceServers(
      turnUrls: 'turn:relay.example.com:3478',
      turnUsername: '',
      turnCredential: 'secret',
    );

    expect(servers, hasLength(1));
    expect(servers.single['urls'], isA<List<String>>());
  });

  test('adds valid UDP, TCP, and TLS TURN endpoints', () {
    final servers = buildWebRtcIceServers(
      turnUrls:
          'turn:relay.example.com:3478?transport=udp, '
          'turn:relay.example.com:3478?transport=tcp, '
          'turns:relay.example.com:5349',
      turnUsername: 'class-user',
      turnCredential: 'class-password',
    );

    expect(servers, hasLength(2));
    expect(servers.last, <String, dynamic>{
      'urls': <String>[
        'turn:relay.example.com:3478?transport=udp',
        'turn:relay.example.com:3478?transport=tcp',
        'turns:relay.example.com:5349',
      ],
      'username': 'class-user',
      'credential': 'class-password',
    });
  });

  test('ignores non-TURN URLs supplied through the TURN setting', () {
    final servers = buildWebRtcIceServers(
      turnUrls: 'https://example.com,stun:example.com:3478',
      turnUsername: 'user',
      turnCredential: 'password',
    );

    expect(servers, hasLength(1));
  });
}
