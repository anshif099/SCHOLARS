import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef CloudflareRemoteStreamCallback =
    void Function(
      String participantId,
      MediaStream stream,
      String? videoTrackId,
    );

typedef CloudflareRemoteRemovedCallback = void Function(String participantId);

class CloudflareSfuService {
  CloudflareSfuService({
    required this.classId,
    required this.participantId,
    required this.connectionId,
    required this.localStream,
    required this.onRemoteStream,
    required this.onRemoteParticipantRemoved,
    required this.onConnectionLost,
  });

  final String classId;
  final String participantId;
  final String connectionId;
  final MediaStream localStream;
  final CloudflareRemoteStreamCallback onRemoteStream;
  final CloudflareRemoteRemovedCallback onRemoteParticipantRemoved;
  final void Function() onConnectionLost;

  final HttpsCallable _callable =
      FirebaseFunctions.instanceFor(region: 'asia-south1').httpsCallable(
        'cloudflareSfu',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );

  final Map<String, _SfuTrackReference> _referencesByMid =
      <String, _SfuTrackReference>{};
  final Map<String, _SfuTrackReference> _referencesByTrackName =
      <String, _SfuTrackReference>{};
  final Map<String, MediaStream> _remoteStreams = <String, MediaStream>{};
  final List<_PendingRemoteTrack> _pendingRemoteTracks =
      <_PendingRemoteTrack>[];

  RTCPeerConnection? _producer;
  RTCPeerConnection? _consumer;
  Future<void>? _subscriptionTask;
  Timer? _pendingTrackRetryTimer;
  bool _subscriptionSyncRequested = false;
  bool _closed = false;
  bool _connectionLostReported = false;

  bool get isStarted => !_closed && _producer != null && _consumer != null;

  Future<List<RTCRtpSender>> getSenders() {
    final producer = _producer;
    if (producer == null) {
      return Future<List<RTCRtpSender>>.value(<RTCRtpSender>[]);
    }
    return producer.getSenders();
  }

  Future<void> start() async {
    if (_closed) {
      throw StateError('The Cloudflare SFU service is closed.');
    }
    final created = await _call(<String, dynamic>{'action': 'create'});
    _requiredString(created, 'producerSessionId');
    _requiredString(created, 'consumerSessionId');

    final producer = await createPeerConnection(_configuration);
    final consumer = await createPeerConnection(_configuration);
    _producer = producer;
    _consumer = consumer;
    _watchConnection(producer);
    _watchConnection(consumer);
    consumer.onTrack = (event) => unawaited(_handleRemoteTrack(event));

    final published = <Map<String, dynamic>>[];
    for (final track in localStream.getTracks()) {
      if (track.kind != 'audio' && track.kind != 'video') continue;
      final transceiver = await producer.addTransceiver(
        track: track,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendOnly,
          streams: <MediaStream>[localStream],
          // Publish three small simulcast layers. Cloudflare can forward a
          // thumbnail layer for the participant grid and a clearer layer for
          // the teacher instead of sending every subscriber full resolution.
          sendEncodings: track.kind == 'video'
              ? <RTCRtpEncoding>[
                  RTCRtpEncoding(
                    rid: 'f',
                    maxBitrate: 180 * 1000,
                    maxFramerate: 15,
                    scaleResolutionDownBy: 1,
                  ),
                  RTCRtpEncoding(
                    rid: 'h',
                    maxBitrate: 100 * 1000,
                    maxFramerate: 12,
                    scaleResolutionDownBy: 2,
                  ),
                  RTCRtpEncoding(
                    rid: 'q',
                    maxBitrate: 45 * 1000,
                    maxFramerate: 8,
                    scaleResolutionDownBy: 4,
                  ),
                ]
              : null,
        ),
      );
      published.add(<String, dynamic>{
        'kind': track.kind,
        'transceiver': transceiver,
      });
    }
    if (published.isEmpty) {
      throw StateError('No local audio or video track is available.');
    }

    final offer = await producer.createOffer();
    await producer.setLocalDescription(offer);
    final tracks = published.map((item) {
      final transceiver = item['transceiver'] as RTCRtpTransceiver;
      final mid = transceiver.mid;
      if (mid.isEmpty) {
        throw StateError('WebRTC did not assign a media section identifier.');
      }
      return <String, dynamic>{'kind': item['kind'], 'mid': mid};
    }).toList();
    final response = await _call(<String, dynamic>{
      'action': 'publish',
      'sessionDescription': _description(offer, 'offer'),
      'tracks': tracks,
    });
    final answer = _sessionDescription(
      response['sessionDescription'],
      'answer',
    );
    await producer.setRemoteDescription(answer);
  }

  Future<void> syncSubscriptions() {
    if (_closed || _consumer == null) return Future<void>.value();
    _subscriptionSyncRequested = true;
    final current = _subscriptionTask;
    if (current != null) return current;

    final task = _drainSubscriptionSync();
    _subscriptionTask = task;
    return task.whenComplete(() {
      if (identical(_subscriptionTask, task)) {
        _subscriptionTask = null;
      }
    });
  }

  Future<void> _drainSubscriptionSync() async {
    while (_subscriptionSyncRequested && !_closed) {
      _subscriptionSyncRequested = false;
      await _syncSubscriptionsOnce();
    }
  }

  Future<void> _syncSubscriptionsOnce() async {
    final consumer = _consumer;
    if (consumer == null) return;
    final response = await _call(<String, dynamic>{'action': 'subscribe'});
    final subscriptions = _mapList(response['subscriptions']);
    final nextReferences = <String, _SfuTrackReference>{};
    final nextTrackNameReferences = <String, _SfuTrackReference>{};
    for (final subscription in subscriptions) {
      final mid = _requiredString(subscription, 'mid');
      final reference = _SfuTrackReference(
        participantId: _requiredString(subscription, 'participantId'),
        kind: _requiredString(subscription, 'kind'),
      );
      nextReferences[mid] = reference;

      // Cloudflare uses the published track name as the receiver track ID.
      // On some native WebRTC builds onTrack fires before transceiver.mid is
      // populated, so keep this second stable lookup instead of dropping the
      // teacher's audio/video event.
      final trackName = subscription['trackName']?.toString();
      if (trackName != null && trackName.isNotEmpty) {
        nextTrackNameReferences[trackName] = reference;
      }
    }
    _referencesByMid
      ..clear()
      ..addAll(nextReferences);
    _referencesByTrackName
      ..clear()
      ..addAll(nextTrackNameReferences);

    await _drainPendingRemoteTracks();

    final activeParticipantIds = nextReferences.values
        .map((reference) => reference.participantId)
        .toSet();
    for (final remoteId in List<String>.from(_remoteStreams.keys)) {
      if (!activeParticipantIds.contains(remoteId)) {
        final stream = _remoteStreams.remove(remoteId);
        await stream?.dispose();
        onRemoteParticipantRemoved(remoteId);
      }
    }

    if (response['hasMoreSubscriptions'] == true) {
      _subscriptionSyncRequested = true;
    }
    if (response['requiresImmediateRenegotiation'] != true) return;
    final offer = _sessionDescription(response['sessionDescription'], 'offer');
    await consumer.setRemoteDescription(offer);
    final localAnswer = await consumer.createAnswer();
    await consumer.setLocalDescription(localAnswer);
    await _call(<String, dynamic>{
      'action': 'renegotiate',
      'sessionDescription': _description(localAnswer, 'answer'),
    });
  }

  Future<void> _handleRemoteTrack(
    RTCTrackEvent event, {
    int retryCount = 0,
  }) async {
    if (_closed) return;
    final mid = event.transceiver?.mid;
    final trackId = event.track.id;
    final reference =
        (mid == null ? null : _referencesByMid[mid]) ??
        (trackId == null ? null : _referencesByTrackName[trackId]);
    if (reference == null) {
      // Native Unified Plan can deliver onTrack just before it exposes the
      // transceiver MID. Give that metadata (and a concurrent subscription
      // refresh) a brief chance to settle rather than losing the event.
      if (retryCount < 10) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!_closed) {
          await _handleRemoteTrack(event, retryCount: retryCount + 1);
        }
      } else if (!_pendingRemoteTracks.any(
        (pending) => identical(pending.event.track, event.track),
      )) {
        // A busy native device can emit onTrack well before it exposes the MID
        // or before a later subscription batch returns its metadata. Retain
        // the one-shot event and retry it after every subscription refresh.
        // Without this queue, teacher audio could be lost for the whole call.
        _pendingRemoteTracks.add(
          _PendingRemoteTrack(event: event, queuedAt: DateTime.now()),
        );
        if (_pendingRemoteTracks.length > 128) {
          _pendingRemoteTracks.removeAt(0);
        }
        _schedulePendingTrackRetry();
      }
      return;
    }

    var stream = _remoteStreams[reference.participantId];
    if (stream == null) {
      stream = await createLocalMediaStream(
        'sfu_${reference.participantId}_$connectionId',
      );
      if (_closed) {
        await stream.dispose();
        return;
      }
      _remoteStreams[reference.participantId] = stream;
    }
    if (trackId == null || trackId.isEmpty) return;
    if (reference.kind == 'audio') {
      // Some native WebRTC implementations deliver subscribed audio tracks in
      // a disabled state until the application explicitly enables them.
      event.track.enabled = true;
    }
    if (stream.getTrackById(trackId) == null) {
      await stream.addTrack(event.track);
    }
    onRemoteStream(
      reference.participantId,
      stream,
      reference.kind == 'video' ? trackId : null,
    );
  }

  Future<void> _drainPendingRemoteTracks() async {
    _pendingTrackRetryTimer?.cancel();
    _pendingTrackRetryTimer = null;
    if (_pendingRemoteTracks.isEmpty || _closed) return;
    final pending = List<_PendingRemoteTrack>.from(_pendingRemoteTracks);
    _pendingRemoteTracks.clear();
    final expiry = DateTime.now().subtract(const Duration(seconds: 30));
    for (final item in pending) {
      if (_closed) return;
      if (item.queuedAt.isBefore(expiry)) continue;
      final event = item.event;
      final mid = event.transceiver?.mid;
      final trackId = event.track.id;
      final canResolve =
          (mid != null && _referencesByMid.containsKey(mid)) ||
          (trackId != null && _referencesByTrackName.containsKey(trackId));
      if (canResolve) {
        await _handleRemoteTrack(event);
      } else {
        _pendingRemoteTracks.add(item);
      }
    }
    if (_pendingRemoteTracks.isNotEmpty) {
      _schedulePendingTrackRetry();
    }
  }

  void _schedulePendingTrackRetry() {
    if (_closed || _pendingTrackRetryTimer?.isActive == true) return;
    _pendingTrackRetryTimer = Timer(const Duration(milliseconds: 500), () {
      _pendingTrackRetryTimer = null;
      unawaited(_drainPendingRemoteTracks());
    });
  }

  void _watchConnection(RTCPeerConnection connection) {
    connection.onConnectionState = (state) {
      if (_closed || _connectionLostReported) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _connectionLostReported = true;
        onConnectionLost();
      }
    };
    connection.onIceConnectionState = (state) {
      if (_closed || _connectionLostReported) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _connectionLostReported = true;
        onConnectionLost();
      }
    };
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pendingTrackRetryTimer?.cancel();
    _pendingTrackRetryTimer = null;
    final subscriptionTask = _subscriptionTask;
    if (subscriptionTask != null) {
      try {
        await subscriptionTask.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await _call(<String, dynamic>{
        'action': 'close',
      }).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Cloudflare automatically expires inactive tracks. Local cleanup must
      // continue even if the network is already unavailable.
    }
    await _producer?.close();
    await _consumer?.close();
    _producer = null;
    _consumer = null;
    for (final stream in _remoteStreams.values) {
      await stream.dispose();
    }
    _remoteStreams.clear();
    _referencesByMid.clear();
    _referencesByTrackName.clear();
    _pendingRemoteTracks.clear();
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> data) async {
    final result = await _callable.call<dynamic>(<String, dynamic>{
      ...data,
      'classId': classId,
      'participantId': participantId,
      'connectionId': connectionId,
    });
    if (result.data is! Map) {
      throw StateError('The Cloudflare SFU function returned invalid data.');
    }
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Map<String, dynamic> get _configuration => <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[
      <String, dynamic>{'urls': 'stun:stun.cloudflare.com:3478'},
    ],
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
  };

  static Map<String, dynamic> _description(
    RTCSessionDescription description,
    String type,
  ) {
    final sdp = description.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('WebRTC did not create an SDP description.');
    }
    return <String, dynamic>{'sdp': sdp, 'type': type};
  }

  static RTCSessionDescription _sessionDescription(
    dynamic value,
    String expectedType,
  ) {
    if (value is! Map) {
      throw StateError('The Cloudflare SFU response is missing SDP.');
    }
    final map = Map<String, dynamic>.from(value);
    final sdp = map['sdp']?.toString();
    final type = map['type']?.toString();
    if (sdp == null || sdp.isEmpty || type != expectedType) {
      throw StateError('The Cloudflare SFU returned invalid SDP.');
    }
    return RTCSessionDescription(sdp, type);
  }

  static String _requiredString(Map<dynamic, dynamic> map, String key) {
    final value = map[key]?.toString();
    if (value == null || value.isEmpty) {
      throw StateError('The Cloudflare SFU response is missing $key.');
    }
    return value;
  }

  static List<Map<String, dynamic>> _mapList(dynamic value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
}

class _SfuTrackReference {
  const _SfuTrackReference({required this.participantId, required this.kind});

  final String participantId;
  final String kind;
}

class _PendingRemoteTrack {
  const _PendingRemoteTrack({required this.event, required this.queuedAt});

  final RTCTrackEvent event;
  final DateTime queuedAt;
}
