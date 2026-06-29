import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/web_recording_helper.dart';

import '../services/firebase_upload_auth_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';

class LiveVideoRoomPage extends StatefulWidget {
  static final Set<String> _activeSessionKeys = <String>{};

  final bool isTeacher;
  final String classId;
  final String topic;
  final String? subjectId;
  final String? participantId;
  final String? participantName;

  const LiveVideoRoomPage({
    super.key,
    required this.isTeacher,
    required this.classId,
    required this.topic,
    this.subjectId,
    this.participantId,
    this.participantName,
  });

  @override
  State<LiveVideoRoomPage> createState() => _LiveVideoRoomPageState();
}

class _LiveVideoRoomPageState extends State<LiveVideoRoomPage> {
  static const int _callVideoWidth = 640;
  static const int _callVideoHeight = 360;
  static const int _callVideoMinFrameRate = 24;
  static const int _callVideoMaxFrameRate = 30;
  static const int _callVideoMaxBitrate = 500 * 1000;
  static const int _recordingWidth = 640;
  static const int _recordingHeight = 360;
  static const int _recordingMaxFrameRate = 30;
  static const int _recordingTargetKbPerMinute = 1000;
  static const String _recordingQuality = '360p';
  static const Duration _recorderStopTimeout = Duration(seconds: 10);
  static const Duration _roomCleanupTimeout = Duration(seconds: 6);
  static const Duration _uploadTimeout = Duration(minutes: 5);

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers =
      <String, RTCVideoRenderer>{};
  final Map<String, _PeerSession> _peerSessions = <String, _PeerSession>{};
  final Set<String> _teacherPeerStartInProgress = <String>{};
  final Map<String, dynamic> _sdpConstraints = <String, dynamic>{
    'mandatory': <String, dynamic>{
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
    'optional': <dynamic>[],
  };

  MediaStream? _localStream;
  MediaStreamTrack? _localAudioTrack;
  MediaStreamTrack? _localVideoTrack;

  StreamSubscription<DatabaseEvent>? _participantsSub;
  StreamSubscription<DatabaseEvent>? _classStatusSub;

  bool _isInitializing = true;
  bool _isMicMuted = false;
  bool _isVideoOff = false;
  bool _isRemoteConnected = false;
  bool _isPipOnRight = true;
  bool _showOwnCameraSmall = true;
  bool _hasEndedCall = false;
  bool _isCleaningUp = false;
  bool _isRecording = false;
  bool _isFrontCamera = true;
  bool _renderersInitialized = false;
  bool _hasClaimedSession = false;
  bool _isProcessing = false;
  bool _isSavingRecording = false;
  MediaRecorder? _mediaRecorder;
  String? _localVideoPath;
  Future<bool>? _recordingSaveTask;
  DateTime? _callStartedAt;
  DateTime? _recordingStartTime;
  bool _isSpeakerOn = true;
  Timer? _recordingTimer;
  RTCPeerConnection? _loopbackConnectionA;
  RTCPeerConnection? _loopbackConnectionB;
  Uint8List? _webRecordedBytes;
  final _webRecordingHelper = WebRecordingHelper();

  String _statusMessage = '';
  String? _errorMessage;
  String? _focusedRemotePeerId;
  late String _localParticipantId;
  late String _localParticipantName;

  List<Map<String, dynamic>> _participants = <Map<String, dynamic>>[];

  DatabaseReference get _liveClassRef => FirebaseDatabase.instance
      .ref()
      .child('live_classes')
      .child(widget.classId);

  DatabaseReference get _participantsRef => _liveClassRef.child('participants');

  DatabaseReference get _webrtcRef => _liveClassRef.child('webrtc');

  String get _localRole => widget.isTeacher ? 'teacher' : 'student';

  String get _remoteRole => widget.isTeacher ? 'student' : 'teacher';

  String get _localSignalRole => widget.isTeacher ? 'teacher' : 'student';

  String get _remoteSignalRole => widget.isTeacher ? 'student' : 'teacher';

  String get _sessionKey =>
      '$_localRole:${widget.classId}:$_localParticipantId';

  DatabaseReference _peerSignalRef(String peerId) =>
      _webrtcRef.child('peers').child(peerId);

  Map<String, dynamic> get _rtcConfiguration => <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>[
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
          'stun:stun2.l.google.com:19302',
          'stun:stun3.l.google.com:19302',
          'stun:stun4.l.google.com:19302',
        ],
      },
    ],
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': 'all',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 10,
  };

  @override
  void initState() {
    super.initState();
    _localParticipantId = _buildLocalParticipantId();
    _localParticipantName = _buildLocalParticipantName();
    _callStartedAt = DateTime.now();
    _statusMessage = widget.isTeacher
        ? 'Preparing your classroom...'
        : 'Joining ${widget.topic}...';

    if (!_claimSession()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          _failAndClose('This live class is already open on this device.'),
        );
      });
      return;
    }

    unawaited(_enableScreenAwake());
    _bootstrapCall();
  }

  String _buildLocalParticipantId() {
    final providedId = widget.participantId?.trim();
    if (providedId != null && providedId.isNotEmpty) {
      return _sanitizeFirebaseKey(providedId);
    }

    if (widget.isTeacher) {
      return 'teacher';
    }

    final fallbackId =
        'student_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1 << 32)}';
    return _sanitizeFirebaseKey(fallbackId);
  }

  String _buildLocalParticipantName() {
    final providedName = widget.participantName?.trim();
    if (providedName != null && providedName.isNotEmpty) {
      return providedName;
    }

    return widget.isTeacher ? 'Teacher' : 'Student';
  }

  String _sanitizeFirebaseKey(String value) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[.#$\[\]/]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return sanitized.isEmpty ? 'participant' : sanitized;
  }

  bool _claimSession() {
    if (LiveVideoRoomPage._activeSessionKeys.contains(_sessionKey)) {
      return false;
    }

    LiveVideoRoomPage._activeSessionKeys.add(_sessionKey);
    _hasClaimedSession = true;
    return true;
  }

  void _releaseSession() {
    if (!_hasClaimedSession) {
      return;
    }

    LiveVideoRoomPage._activeSessionKeys.remove(_sessionKey);
    _hasClaimedSession = false;
  }

  Future<void> _enableScreenAwake() async {
    try {
      await WakelockPlus.enable();
    } catch (error, stackTrace) {
      _reportNonFatalError('enable screen awake', error, stackTrace);
    }
  }

  Future<void> _disableScreenAwake() async {
    // Keep screen awake globally per user requirements
  }

  Future<void> _bootstrapCall() async {
    try {
      await _localRenderer.initialize();
      _renderersInitialized = true;

      final granted = await PermissionService.requestCameraAndMic();
      if (!granted) {
        await _failAndClose('Camera and microphone permissions are required.');
        return;
      }

      if (WebRTC.platformIsIOS) {
        await Helper.ensureAudioSession();
      }

      if (widget.isTeacher) {
        await _resetTeacherSession();
      }

      await _setupLocalMedia();

      if (!WebRTC.platformIsWeb) {
        // Delay slightly to ensure AudioSwitchManager is active/started,
        // then force speakerphone to be ON by default.
        Future.delayed(const Duration(milliseconds: 500), () async {
          try {
            await Helper.setSpeakerphoneOn(true);
          } catch (e) {
            debugPrint('Failed to set speakerphone on at start: $e');
          }
        });
      }
      _listenToParticipants();
      await _registerParticipant();
      _listenForSignaling();
      if (!widget.isTeacher) {
        _listenForClassStatus();
      }

      if (widget.isTeacher) {
        await _markTeacherClassLive();
        _updateStatus('Waiting for students to join...');
      } else {
        _updateStatus('Connecting to ${widget.topic}...');
      }

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (error) {
      await _failAndClose('Unable to start the live call: $error');
    }
  }

  Future<void> _registerParticipant() async {
    final participantRef = _participantsRef.child(_localParticipantId);

    await participantRef.onDisconnect().remove();
    await participantRef.set(<String, dynamic>{
      'id': _localParticipantId,
      'name': _localParticipantName,
      'role': _localRole,
      'joined_at': ServerValue.timestamp,
      'mic_enabled': !_isMicMuted,
      'video_enabled': !_isVideoOff,
    });
  }

  void _listenToParticipants() {
    _participantsSub = _participantsRef.onValue.listen(
      (event) {
        final rawValue = event.snapshot.value;
        final participants = <Map<String, dynamic>>[];

        if (rawValue is Map) {
          for (final entry in rawValue.entries) {
            if (entry.value is Map) {
              final participant = Map<String, dynamic>.from(entry.value as Map);
              participant['id'] ??= entry.key.toString();
              participants.add(participant);
            }
          }
        }

        if (!mounted) {
          return;
        }

        setState(() {
          _participants = participants;
        });

        if (widget.isTeacher && !_hasRemoteParticipant) {
          _updateStatus('Waiting for students to join...');
        }

        if (widget.isTeacher) {
          unawaited(_syncTeacherStudentPeers(participants));
          if (_hasRemoteParticipant &&
              !_isRecording &&
              !_isSavingRecording &&
              _mediaRecorder == null &&
              _localVideoPath == null &&
              !_isVideoOff) {
            unawaited(_startRecording());
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _reportNonFatalError('participants listener', error, stackTrace);
      },
    );
  }

  Future<void> _setupLocalMedia() async {
    final mediaConstraints = kIsWeb
        ? <String, dynamic>{
            'audio': true,
            'video': <String, dynamic>{
              'width': <String, dynamic>{
                'ideal': _callVideoWidth,
              },
              'height': <String, dynamic>{
                'ideal': _callVideoHeight,
              },
              'frameRate': <String, dynamic>{
                'ideal': _callVideoMaxFrameRate,
              },
              'facingMode': 'user',
            },
          }
        : <String, dynamic>{
            'audio': true,
            'video': <String, dynamic>{
              'mandatory': <String, dynamic>{
                'minWidth': '$_callVideoWidth',
                'minHeight': '$_callVideoHeight',
                'maxWidth': '$_callVideoWidth',
                'maxHeight': '$_callVideoHeight',
                'minFrameRate': '$_callVideoMinFrameRate',
                'maxFrameRate': '$_callVideoMaxFrameRate',
              },
              'facingMode': 'user',
              'optional': <dynamic>[],
            },
          };

    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    _localAudioTrack = _localStream!.getAudioTracks().isNotEmpty
        ? _localStream!.getAudioTracks().first
        : null;
    _localVideoTrack = _localStream!.getVideoTracks().isNotEmpty
        ? _localStream!.getVideoTracks().first
        : null;
    _localRenderer.srcObject = _localStream;
  }

  Future<_PeerSession> _createPeerSession(String peerId) async {
    final existingSession = _peerSessions[peerId];
    if (existingSession != null) {
      return existingSession;
    }

    final localStream = _localStream;
    if (localStream == null) {
      throw StateError('Local media is not ready.');
    }

    final session = _PeerSession(peerId: peerId);
    final peerConnection = await createPeerConnection(_rtcConfiguration);
    session.connection = peerConnection;
    _peerSessions[peerId] = session;

    for (final track in localStream.getTracks()) {
      final sender = await peerConnection.addTrack(track, localStream);
      if (track.kind == 'audio') {
        session.localAudioSender = sender;
      } else if (track.kind == 'video') {
        session.localVideoSender = sender;
      }
    }

    await _applyOutgoingAudioStateForSession(session, muted: _isMicMuted);
    await _applyOutgoingVideoLimitsForSession(session);

    peerConnection.onIceCandidate = (candidate) async {
      if (_hasEndedCall || _isCleaningUp) {
        return;
      }

      final candidateValue = candidate.candidate;
      if (candidateValue == null || candidateValue.isEmpty) {
        return;
      }

      try {
        await _peerSignalRef(peerId)
            .child('candidates')
            .child(_localSignalRole)
            .push()
            .set(<String, dynamic>{
              'candidate': candidateValue,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
              'created_at': ServerValue.timestamp,
            });
      } catch (error, stackTrace) {
        _reportNonFatalError('publish local candidate', error, stackTrace);
      }
    };

    peerConnection.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _attachRemoteStream(peerId, event.streams.first);
      }
    };

    peerConnection.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _handlePeerConnected(peerId);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          _updateStatus('Connecting call...');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _handleRemoteDisconnect(
            peerId,
            'Connection lost. Waiting to reconnect...',
          );
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _handleRemoteDisconnect(peerId, 'Call connection failed.');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _handleRemoteDisconnect(peerId, 'Call ended.');
          break;
        default:
          break;
      }
    };

    peerConnection.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          _updateStatus('Negotiating secure media channel...');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _handlePeerConnected(peerId);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _handleRemoteDisconnect(peerId, 'Peer disconnected.');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _handleRemoteDisconnect(peerId, 'Unable to establish the call.');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _handleRemoteDisconnect(peerId, 'Call ended.');
          break;
        default:
          break;
      }
    };

    return session;
  }

  Future<void> _syncTeacherStudentPeers(
    List<Map<String, dynamic>> participants,
  ) async {
    if (!widget.isTeacher ||
        _hasEndedCall ||
        _isCleaningUp ||
        _localStream == null) {
      return;
    }

    final studentIds = participants
        .where((participant) => participant['role'] == 'student')
        .map((participant) => participant['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    for (final peerId in List<String>.from(_peerSessions.keys)) {
      if (!studentIds.contains(peerId)) {
        await _closePeerSession(peerId, removeSignals: true);
      }
    }

    for (final studentId in studentIds) {
      if (_peerSessions.containsKey(studentId) ||
          _teacherPeerStartInProgress.contains(studentId)) {
        continue;
      }

      await _startTeacherPeer(studentId);
    }
  }

  Future<void> _startTeacherPeer(String studentId) async {
    _teacherPeerStartInProgress.add(studentId);

    try {
      final session = await _createPeerSession(studentId);
      _listenToRemoteCandidates(session);
      session.answerSub = _peerSignalRef(studentId)
          .child('answer')
          .onValue
          .listen(
            (event) => unawaited(_handleAnswerUpdated(studentId, event)),
            onError: (Object error, StackTrace stackTrace) {
              _reportNonFatalError('answer listener', error, stackTrace);
            },
          );

      await _createAndSendOffer(studentId);
    } catch (error, stackTrace) {
      _reportNonFatalError('start teacher peer', error, stackTrace);
      await _closePeerSession(studentId, removeSignals: true);
    } finally {
      _teacherPeerStartInProgress.remove(studentId);
    }
  }

  Future<void> _startStudentPeer() async {
    if (_peerSessions.containsKey(_localParticipantId) ||
        _hasEndedCall ||
        _isCleaningUp) {
      return;
    }

    try {
      final session = await _createPeerSession(_localParticipantId);
      _listenToRemoteCandidates(session);
      session.offerSub = _peerSignalRef(_localParticipantId)
          .child('offer')
          .onValue
          .listen(
            (event) =>
                unawaited(_handleOfferUpdated(_localParticipantId, event)),
            onError: (Object error, StackTrace stackTrace) {
              _reportNonFatalError('offer listener', error, stackTrace);
            },
          );
    } catch (error, stackTrace) {
      _reportNonFatalError('start student peer', error, stackTrace);
    }
  }

  void _listenToRemoteCandidates(_PeerSession session) {
    if (session.remoteCandidatesSub != null) {
      return;
    }

    session.remoteCandidatesSub = _peerSignalRef(session.peerId)
        .child('candidates')
        .child(_remoteSignalRole)
        .onChildAdded
        .listen(
          (event) =>
              unawaited(_handleRemoteCandidateAdded(session.peerId, event)),
          onError: (Object error, StackTrace stackTrace) {
            _reportNonFatalError(
              'remote candidate listener',
              error,
              stackTrace,
            );
          },
        );
  }

  Future<void> _applyOutgoingAudioState({required bool muted}) async {
    final audioTrack = _localAudioTrack;
    if (audioTrack == null) {
      return;
    }

    audioTrack.enabled = !muted;

    await Future.wait(
      _peerSessions.values.map(
        (session) => _applyOutgoingAudioStateForSession(session, muted: muted),
      ),
    );
  }

  Future<void> _applyOutgoingAudioStateForSession(
    _PeerSession session, {
    required bool muted,
  }) async {
    final audioTrack = _localAudioTrack;
    final sender = session.localAudioSender;
    if (audioTrack == null) {
      return;
    }

    if (sender == null) {
      return;
    }

    try {
      final parameters = sender.parameters;
      final encodings = parameters.encodings;
      if (encodings != null && encodings.isNotEmpty) {
        for (final encoding in encodings) {
          encoding.active = !muted;
        }
        await sender.setParameters(parameters);
      }

      if (!muted) {
        await sender.replaceTrack(audioTrack);
      }
    } catch (error, stackTrace) {
      _reportNonFatalError('apply outgoing audio state', error, stackTrace);

      if (!muted) {
        try {
          await sender.replaceTrack(audioTrack);
        } catch (replaceError, replaceStackTrace) {
          _reportNonFatalError(
            'restore outgoing audio track',
            replaceError,
            replaceStackTrace,
          );
        }
      }
    }
  }

  Future<void> _applyOutgoingVideoLimitsForSession(_PeerSession session) async {
    final sender = session.localVideoSender;
    if (sender == null) {
      return;
    }

    try {
      final parameters = sender.parameters;
      parameters.degradationPreference = RTCDegradationPreference.BALANCED;

      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) {
        parameters.encodings = <RTCRtpEncoding>[
          RTCRtpEncoding(
            maxBitrate: _callVideoMaxBitrate,
            maxFramerate: _callVideoMaxFrameRate,
            scaleResolutionDownBy: 1.0,
            priority: RTCPriorityType.high,
            networkPriority: RTCPriorityType.high,
          ),
        ];
      } else {
        for (final encoding in encodings) {
          encoding.maxBitrate = _callVideoMaxBitrate;
          encoding.maxFramerate = _callVideoMaxFrameRate;
          encoding.scaleResolutionDownBy ??= 1.0;
          encoding.priority = RTCPriorityType.high;
          encoding.networkPriority = RTCPriorityType.high;
        }
      }

      await sender.setParameters(parameters);
    } catch (error, stackTrace) {
      _reportNonFatalError('apply outgoing video limits', error, stackTrace);
    }
  }

  void _listenForSignaling() {
    if (!widget.isTeacher) {
      unawaited(_startStudentPeer());
    }
  }

  void _listenForClassStatus() {
    _classStatusSub = _liveClassRef.onValue.listen((event) {
      if (!mounted || widget.isTeacher) return;

      final data = event.snapshot.value;
      if (data == null) {
        // Teacher ended the call and removed the node
        debugPrint('Teacher ended the call (node removed)');
        unawaited(_endCall());
        return;
      }

      if (data is Map) {
        final isLive = data['is_live'] ?? false;
        if (!isLive) {
          debugPrint('Teacher ended the call (is_live: false)');
          unawaited(_endCall());
        }
      }
    });
  }

  Future<void> _handleRemoteCandidateAdded(
    String peerId,
    DatabaseEvent event,
  ) async {
    if (_hasEndedCall || _isCleaningUp) {
      return;
    }

    try {
      final session = _peerSessions[peerId];
      if (session == null || session.isClosing) {
        return;
      }

      final candidateKey = event.snapshot.key;
      final rawValue = event.snapshot.value;

      if (candidateKey == null ||
          rawValue == null ||
          session.processedRemoteCandidateKeys.contains(candidateKey)) {
        return;
      }

      session.processedRemoteCandidateKeys.add(candidateKey);

      if (rawValue is! Map) {
        return;
      }

      final candidateMap = Map<String, dynamic>.from(rawValue);
      final candidateValue = candidateMap['candidate']?.toString();

      if (candidateValue == null || candidateValue.isEmpty) {
        return;
      }

      final candidate = RTCIceCandidate(
        candidateValue,
        candidateMap['sdpMid']?.toString(),
        _parseInt(candidateMap['sdpMLineIndex']),
      );

      final peerConnection = session.connection;
      if (session.remoteDescriptionApplied && peerConnection != null) {
        try {
          await peerConnection.addCandidate(candidate);
        } catch (error, stackTrace) {
          session.pendingRemoteCandidates.add(candidate);
          _reportNonFatalError('add remote candidate', error, stackTrace);
        }
      } else {
        session.pendingRemoteCandidates.add(candidate);
      }
    } catch (error, stackTrace) {
      _reportNonFatalError('handle remote candidate', error, stackTrace);
    }
  }

  Future<void> _handleAnswerUpdated(String peerId, DatabaseEvent event) async {
    if (_hasEndedCall || _isCleaningUp) {
      return;
    }

    try {
      final session = _peerSessions[peerId];
      final peerConnection = session?.connection;
      if (session == null || session.isClosing || peerConnection == null) {
        return;
      }

      final rawValue = event.snapshot.value;
      if (rawValue is! Map || session.remoteDescriptionApplied) {
        return;
      }

      final answerMap = Map<String, dynamic>.from(rawValue);
      final sdp = answerMap['sdp']?.toString();
      final type = answerMap['type']?.toString();

      if (sdp == null || type == null) {
        return;
      }

      await peerConnection.setRemoteDescription(
        RTCSessionDescription(sdp, type),
      );
      session.remoteDescriptionApplied = true;
      await _flushPendingRemoteCandidates(peerId);
      _updateStatus('Student joined. Connecting media...');
    } catch (error, stackTrace) {
      _reportNonFatalError('apply answer', error, stackTrace);
    }
  }

  Future<void> _handleOfferUpdated(String peerId, DatabaseEvent event) async {
    if (_hasEndedCall || _isCleaningUp) {
      return;
    }

    try {
      final session = _peerSessions[peerId];
      final peerConnection = session?.connection;
      if (session == null || session.isClosing || peerConnection == null) {
        return;
      }

      final rawValue = event.snapshot.value;
      if (rawValue is! Map || session.remoteDescriptionApplied) {
        return;
      }

      final offerMap = Map<String, dynamic>.from(rawValue);
      final sdp = offerMap['sdp']?.toString();
      final type = offerMap['type']?.toString();

      if (sdp == null || type == null) {
        return;
      }

      await peerConnection.setRemoteDescription(
        RTCSessionDescription(sdp, type),
      );
      session.remoteDescriptionApplied = true;
      await _flushPendingRemoteCandidates(peerId);

      final answer = await peerConnection.createAnswer(_sdpConstraints);
      await peerConnection.setLocalDescription(answer);

      await _peerSignalRef(peerId).child('answer').set(<String, dynamic>{
        'type': answer.type,
        'sdp': answer.sdp,
        'created_at': ServerValue.timestamp,
      });

      _updateStatus('Joining live classroom...');
    } catch (error, stackTrace) {
      _reportNonFatalError('apply offer', error, stackTrace);
    }
  }

  Future<void> _resetTeacherSession() async {
    await _webrtcRef.remove();
    await _participantsRef.remove();
    await _webrtcRef.child('status').set('waiting_for_students');
  }

  Future<void> _createAndSendOffer(String peerId) async {
    final session = _peerSessions[peerId];
    final peerConnection = session?.connection;
    if (session == null || session.isClosing || peerConnection == null) {
      return;
    }

    final offer = await peerConnection.createOffer(_sdpConstraints);
    await peerConnection.setLocalDescription(offer);

    await _peerSignalRef(peerId).child('offer').set(<String, dynamic>{
      'type': offer.type,
      'sdp': offer.sdp,
      'created_at': ServerValue.timestamp,
    });
    await _webrtcRef.child('status').set('offer_sent');

    _updateStatus('Waiting for students to join...');
  }

  Future<void> _markTeacherClassLive() async {
    try {
      await _liveClassRef.update(<String, dynamic>{
        'is_live': true,
        'status': 'offer_ready',
        'offer_ready_at': ServerValue.timestamp,
      });
    } catch (error, stackTrace) {
      _reportNonFatalError('mark teacher class live', error, stackTrace);
    }
  }

  Future<void> _flushPendingRemoteCandidates(String peerId) async {
    final session = _peerSessions[peerId];
    final peerConnection = session?.connection;
    if (session == null ||
        peerConnection == null ||
        !session.remoteDescriptionApplied) {
      return;
    }

    final remainingCandidates = <RTCIceCandidate>[];

    for (final candidate in List<RTCIceCandidate>.from(
      session.pendingRemoteCandidates,
    )) {
      try {
        await peerConnection.addCandidate(candidate);
      } catch (error, stackTrace) {
        remainingCandidates.add(candidate);
        _reportNonFatalError('flush pending candidate', error, stackTrace);
      }
    }

    session.pendingRemoteCandidates
      ..clear()
      ..addAll(remainingCandidates);
  }

  void _attachRemoteStream(String peerId, MediaStream stream) {
    unawaited(_attachRemoteStreamInternal(peerId, stream));
  }

  Future<void> _attachRemoteStreamInternal(
    String peerId,
    MediaStream stream,
  ) async {
    if (_hasEndedCall || _isCleaningUp) {
      return;
    }

    var renderer = _remoteRenderers[peerId];
    if (renderer == null) {
      renderer = RTCVideoRenderer();
      _remoteRenderers[peerId] = renderer;
      await renderer.initialize();
    }

    renderer.srcObject = stream;

    if (kIsWeb) {
      renderer.volume = _isSpeakerOn ? 1.0 : 0.15;
    }

    if (kIsWeb && _mediaRecorder != null) {
      _webRecordingHelper.addRemoteStream(stream);
    }

    if (!mounted || _isCleaningUp || _hasEndedCall) {
      return;
    }

    setState(() {
      _focusedRemotePeerId ??= peerId;
      _isRemoteConnected = true;
      _errorMessage = null;
      _statusMessage = _connectedStatusMessage();
    });
  }

  Future<void> _startLoopbackConnection() async {
    try {
      final pcA = await createPeerConnection(_rtcConfiguration);
      final pcB = await createPeerConnection(_rtcConfiguration);

      _loopbackConnectionA = pcA;
      _loopbackConnectionB = pcB;

      final localStream = _localStream;
      final audioTrack = _localAudioTrack;
      if (localStream != null && audioTrack != null) {
        await pcA.addTrack(audioTrack, localStream);
      }

      final List<RTCIceCandidate> candidatesForA = [];
      final List<RTCIceCandidate> candidatesForB = [];
      bool remoteDescSetForA = false;
      bool remoteDescSetForB = false;

      final completer = Completer<void>();

      pcA.onIceConnectionState = (state) {
        debugPrint('Loopback A ICE State: $state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      };

      pcA.onIceCandidate = (candidate) async {
        if (candidate.candidate == null) return;
        if (remoteDescSetForB && _loopbackConnectionB != null) {
          try {
            await pcB.addCandidate(candidate);
          } catch (e) {
            debugPrint('Loopback B addCandidate error: $e');
          }
        } else {
          candidatesForB.add(candidate);
        }
      };

      pcB.onIceCandidate = (candidate) async {
        if (candidate.candidate == null) return;
        if (remoteDescSetForA && _loopbackConnectionA != null) {
          try {
            await pcA.addCandidate(candidate);
          } catch (e) {
            debugPrint('Loopback A addCandidate error: $e');
          }
        } else {
          candidatesForA.add(candidate);
        }
      };

      pcB.onTrack = (event) {
        // Mute incoming tracks on loopback to prevent speaker echo
        event.track.enabled = false;
      };

      final loopbackConstraints = <String, dynamic>{
        'mandatory': <String, dynamic>{
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false,
        },
        'optional': <dynamic>[],
      };

      final offer = await pcA.createOffer(loopbackConstraints);
      await pcA.setLocalDescription(offer);
      await pcB.setRemoteDescription(offer);
      remoteDescSetForB = true;

      for (final cand in candidatesForB) {
        try {
          await pcB.addCandidate(cand);
        } catch (e) {
          debugPrint('Loopback B flush candidate error: $e');
        }
      }
      candidatesForB.clear();

      final answer = await pcB.createAnswer(loopbackConstraints);
      await pcB.setLocalDescription(answer);
      await pcA.setRemoteDescription(answer);
      remoteDescSetForA = true;

      for (final cand in candidatesForA) {
        try {
          await pcA.addCandidate(cand);
        } catch (e) {
          debugPrint('Loopback A flush candidate error: $e');
        }
      }
      candidatesForA.clear();

      debugPrint(
        'Waiting for solo audio-only loopback connection to establish...',
      );
      await completer.future
          .timeout(const Duration(milliseconds: 1500))
          .catchError((_) {
            debugPrint('Loopback connection wait timed out or completed');
          });

      debugPrint(
        'Solo audio-only loopback connection established successfully.',
      );
    } catch (e, s) {
      debugPrint('Failed to start loopback connection: $e');
      debugPrintStack(stackTrace: s);
    }
  }

  void _stopLoopbackConnection() {
    if (_loopbackConnectionA == null && _loopbackConnectionB == null) {
      return;
    }
    debugPrint('Stopping solo loopback connection...');
    try {
      _loopbackConnectionA?.close();
    } catch (e) {
      debugPrint('Failed to close loopback connection A: $e');
    }
    try {
      _loopbackConnectionB?.close();
    } catch (e) {
      debugPrint('Failed to close loopback connection B: $e');
    }
    _loopbackConnectionA = null;
    _loopbackConnectionB = null;
  }

  Future<void> _startRecording() async {
    if (!widget.isTeacher || _mediaRecorder != null || _localStream == null) {
      return;
    }

    if (_isSavingRecording) {
      _showSnackBar('Please wait until the current recording is saved.');
      return;
    }

    if (_localVideoPath != null) {
      _showSnackBar('Save the current recording before starting another.');
      return;
    }

    if (_isVideoOff) {
      _showSnackBar('Turn camera on before recording.');
      return;
    }

    try {
      if (kIsWeb) {
        _localVideoPath = 'web_recording_${DateTime.now().millisecondsSinceEpoch}';
      } else {
        final storageDir = await getApplicationDocumentsDirectory();
        final recDir = Directory('${storageDir.path}/recordings');
        if (!await recDir.exists()) {
          await recDir.create(recursive: true);
        }
        _localVideoPath =
            '${recDir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.mp4';
      }

      _mediaRecorder = MediaRecorder(albumName: '');

      final videoTrack = _localStream!.getVideoTracks().isNotEmpty
          ? _localStream!.getVideoTracks().first
          : null;

      if (kIsWeb) {
        final remoteStreams = _remoteRenderers.values
            .map((r) => r.srcObject)
            .whereType<MediaStream>()
            .toList();
        _webRecordingHelper.start(
          _mediaRecorder!,
          _localStream!,
          remoteStreams: remoteStreams,
        );
      } else if (WebRTC.platformIsAndroid) {
        await _mediaRecorder!.startWithMixedAudio(
          _localVideoPath!,
          videoTrack: videoTrack,
          useFallbackAudio: true,
        );
      } else {
        await _mediaRecorder!.start(
          _localVideoPath!,
          videoTrack: videoTrack,
          audioChannel: RecorderAudioChannel.INPUT,
        );
      }

      _recordingStartTime = DateTime.now();
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {});
        }
      });

      if (mounted) {
        setState(() {
          _isRecording = true;
          _statusMessage = 'Recording started';
        });
      }
      debugPrint('Recording started: $_localVideoPath');
    } catch (e) {
      debugPrint('Failed to start recording: $e');
      _mediaRecorder = null;
      _localVideoPath = null;
      _showSnackBar('Recording could not start.');
    }
  }

  Future<void> _saveRecordingNow() async {
    if (!widget.isTeacher || _isSavingRecording) {
      return;
    }

    if (!_hasPendingRecording) {
      _showSnackBar('Start recording before saving.');
      return;
    }

    final videoPath = _localVideoPath;
    final durationText = _buildRecordingDurationText(
      _recordingStartTime ?? _callStartedAt,
    );
    final recordingFinalized = await _stopTeacherRecording();

    final saved = await _saveRecordingFile(
      videoPath ?? _localVideoPath,
      durationText,
      recordingFinalized: recordingFinalized,
      showResult: true,
    );

    if (!recordingFinalized && _localVideoPath == videoPath) {
      _localVideoPath = null;
      if (mounted) {
        setState(() {});
      }
    }

    if (!saved && mounted) {
      _showSnackBar(
        recordingFinalized
            ? 'Recording save failed. It will retry when the call ends.'
            : 'Recording could not be finalized.',
      );
    }
  }

  Future<bool> _saveRecordingFile(
    String? videoPath,
    String durationText, {
    required bool recordingFinalized,
    required bool showResult,
  }) {
    final activeTask = _recordingSaveTask;
    if (activeTask != null) {
      return activeTask;
    }

    final task = _saveRecordingFileInternal(
      videoPath,
      durationText,
      recordingFinalized: recordingFinalized,
      showResult: showResult,
    );
    _recordingSaveTask = task;
    return task;
  }

  Future<bool> _saveRecordingFileInternal(
    String? videoPath,
    String durationText, {
    required bool recordingFinalized,
    required bool showResult,
  }) async {
    if (mounted) {
      setState(() {
        _isSavingRecording = true;
        _statusMessage = 'Saving recording...';
      });
    }

    try {
      final saved = await _saveRecordingToStorage(
        videoPath,
        durationText,
        recordingFinalized: recordingFinalized,
      );

      if (saved) {
        if (_localVideoPath == videoPath) {
          _localVideoPath = null;
        }
        _recordingStartTime = null;
        if (showResult) {
          _showSnackBar('Recording saved.');
        }
      }

      return saved;
    } finally {
      _recordingSaveTask = null;
      if (mounted) {
        setState(() {
          _isSavingRecording = false;
          if (!_hasEndedCall) {
            _statusMessage = _isRemoteConnected
                ? _connectedStatusMessage()
                : (widget.isTeacher
                      ? 'Waiting for students to join...'
                      : 'Connecting to ${widget.topic}...');
          }
        });
      } else {
        _isSavingRecording = false;
      }
    }
  }

  void _handlePeerConnected(String peerId) {
    if (!mounted || _isCleaningUp || _hasEndedCall) {
      return;
    }

    setState(() {
      _focusedRemotePeerId ??= peerId;
      final connectedCount = _connectedRemoteCount;
      _isRemoteConnected = connectedCount > 0;
      _errorMessage = null;
      _statusMessage = connectedCount > 0
          ? _connectedStatusMessage()
          : 'Connecting media...';
    });
  }

  void _handleRemoteDisconnect(String peerId, String message) {
    final renderer = _remoteRenderers[peerId];
    renderer?.srcObject = null;

    if (!mounted) {
      return;
    }

    setState(() {
      if (_focusedRemotePeerId == peerId) {
        _focusedRemotePeerId = _firstConnectedRemotePeerId;
      }
      _isRemoteConnected = _connectedRemoteCount > 0;
      _statusMessage = message;
    });
  }

  void _updateStatus(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _statusMessage = message;
    });
  }

  Future<void> _syncParticipantMediaState() {
    return _participantsRef.child(_localParticipantId).update(<String, dynamic>{
      'mic_enabled': !_isMicMuted,
      'video_enabled': !_isVideoOff,
    });
  }

  Future<void> _toggleMic() async {
    final nextValue = !_isMicMuted;
    await _applyOutgoingAudioState(muted: nextValue);

    if (mounted) {
      setState(() {
        _isMicMuted = nextValue;
      });
    }

    await _syncParticipantMediaState();
  }

  Future<void> _toggleVideo() async {
    final nextValue = !_isVideoOff;
    _localVideoTrack?.enabled = !nextValue;

    if (mounted) {
      setState(() {
        _isVideoOff = nextValue;
      });
    }

    await _syncParticipantMediaState();
  }

  Future<void> _switchCamera() async {
    if (_localVideoTrack == null) {
      return;
    }

    await Helper.switchCamera(_localVideoTrack!);
    if (mounted) {
      setState(() {
        _isFrontCamera = !_isFrontCamera;
      });
    }
  }

  Future<void> _failAndClose(String message) async {
    _hasEndedCall = true;
    _errorMessage = message;
    await _cleanupRoomState(removeLiveClass: widget.isTeacher);

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _hideVideoViewsForTeardown() async {
    if (_renderersInitialized) {
      _localRenderer.srcObject = null;
      for (final renderer in _remoteRenderers.values) {
        renderer.srcObject = null;
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isRemoteConnected = false;
      _isVideoOff = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  Future<bool> _stopTeacherRecording() async {
    final recorder = _mediaRecorder;
    if (!widget.isTeacher || recorder == null) {
      return true;
    }

    if (mounted) {
      setState(() => _statusMessage = 'Finalizing video...');
    }

    _recordingTimer?.cancel();
    _recordingTimer = null;
    _mediaRecorder = null;
    if (mounted) {
      setState(() => _isRecording = false);
    }

    bool success = false;
    try {
      if (kIsWeb) {
        _webRecordedBytes = await _webRecordingHelper.stop();
        success = _webRecordedBytes != null && _webRecordedBytes!.isNotEmpty;
      } else {
        await recorder.stop().timeout(_recorderStopTimeout);
        debugPrint('MediaRecorder stopped successfully');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        success = true;
      }
    } on TimeoutException {
      debugPrint('MediaRecorder stop timed out after $_recorderStopTimeout');
      success = false;
    } catch (e) {
      debugPrint('Failed to stop recording: $e');
      success = false;
    } finally {
      _stopLoopbackConnection();
    }
    return success;
  }

  Future<void> _endCall() async {
    if (_hasEndedCall) {
      return;
    }

    _hasEndedCall = true;
    final pendingSaveTask = _recordingSaveTask;
    final shouldAutoSaveRecording =
        widget.isTeacher && pendingSaveTask == null && _hasPendingRecording;
    final videoPath = _localVideoPath;
    final durationText = _buildRecordingDurationText(
      _recordingStartTime ?? _callStartedAt,
    );

    if (mounted && widget.isTeacher) {
      setState(() {
        _isProcessing = true;
        _statusMessage = 'Ending session...';
      });
      // Signal students to leave IMMEDIATELY
      unawaited(_liveClassRef.child('is_live').set(false));
    }

    if (mounted) {
      setState(() => _statusMessage = 'Closing camera...');
    }
    await _hideVideoViewsForTeardown();

    // STEP 1: Stop the MediaRecorder after detaching views. Native stop is
    // bounded so a stuck encoder cannot freeze the Android main thread.
    final recordingFinalized = shouldAutoSaveRecording
        ? await _stopTeacherRecording()
        : true;

    // STEP 2: Clean up WebRTC (signals termination to student immediately via node removal)
    try {
      await _cleanupRoomState(
        removeLiveClass: widget.isTeacher,
      ).timeout(_roomCleanupTimeout);
    } on TimeoutException {
      debugPrint('Room cleanup timed out after $_roomCleanupTimeout');
      _releaseSession();
    }

    // STEP 3: Save the recording before leaving the call screen. The upload
    // method creates the RTDB row first, so the class is visible even if the
    // Storage upload later fails.
    if (widget.isTeacher) {
      if (mounted && (pendingSaveTask != null || shouldAutoSaveRecording)) {
        setState(() => _statusMessage = 'Saving recording...');
      }
      if (pendingSaveTask != null) {
        await pendingSaveTask;
      } else if (shouldAutoSaveRecording) {
        await _saveRecordingFile(
          videoPath ?? _localVideoPath,
          durationText,
          recordingFinalized: recordingFinalized,
          showResult: false,
        );
      }
    }

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// Uploads the recorded MP4 to Firebase Storage and writes metadata to RTDB.
  Future<bool> _saveRecordingToStorage(
    String? videoPath,
    String durationText, {
    required bool recordingFinalized,
  }) async {
    String? videoUrl;
    String? storagePath;
    String? uploadError;
    int? fileSizeBytes;
    String uploadStatus = 'no_file';
    final recordedAt = DateTime.now().millisecondsSinceEpoch;

    final recordedRef = FirebaseDatabase.instance
        .ref()
        .child('recorded_classes')
        .child(widget.classId)
        .push();

    Future<void> updateRecordedClass(Map<String, dynamic> values) async {
      try {
        await recordedRef.update(values);
      } catch (e) {
        debugPrint('Failed to update recorded_classes metadata: $e');
      }
    }

    Future<void> markRecordingFailed(String status, String error) async {
      uploadStatus = status;
      uploadError = error;
      await updateRecordedClass(<String, dynamic>{
        'upload_status': uploadStatus,
        'upload_error': uploadError,
        'file_size_bytes': ?fileSizeBytes,
        'storage_path': ?storagePath,
      });
    }

    try {
      await recordedRef.set(<String, dynamic>{
        'key': recordedRef.key,
        'topic': widget.topic,
        'subject_id': widget.subjectId,
        'date': recordedAt,
        'duration': durationText,
        'thumbnail_color': Random().nextInt(0xFFFFFF),
        'quality': _recordingQuality,
        'width': _recordingWidth,
        'height': _recordingHeight,
        'max_frame_rate': _recordingMaxFrameRate,
        'live_bandwidth_kbps': _callVideoMaxBitrate ~/ 1000,
        'target_kb_per_minute': _recordingTargetKbPerMinute,
        'upload_status': 'preparing',
      });
      debugPrint('Initial metadata saved to recorded_classes');
    } catch (e) {
      debugPrint('Failed to create recorded_classes metadata: $e');
    }

    if (!recordingFinalized) {
      await markRecordingFailed(
        'finalization_failed',
        'Recording could not be finalized safely.',
      );
      return false;
    } else if (kIsWeb) {
      if (_webRecordedBytes == null || _webRecordedBytes!.isEmpty) {
        debugPrint('Recording upload skipped: no bytes recorded.');
        await markRecordingFailed('empty_file', 'No bytes were recorded.');
        return false;
      }

      final authUid = await FirebaseUploadAuthService.ensureSignedIn();
      if (authUid == null) {
        await markRecordingFailed(
          'auth_failed',
          'Firebase Anonymous Authentication is not enabled or sign-in failed. Enable Authentication > Sign-in method > Anonymous in Firebase Console.',
        );
        return false;
      }

      if (mounted) {
        setState(() => _statusMessage = 'Uploading video...');
      }

      final recordedMime = _webRecordingHelper.recordedMimeType;
      final fileExtension = recordedMime.contains('mp4') ? 'mp4' : 'webm';

      fileSizeBytes = _webRecordedBytes!.length;
      storagePath =
          'recorded_classes/${widget.classId}/${recordedAt}_360p_1mbpm.$fileExtension';
      final storageRef = FirebaseStorage.instance.ref().child(storagePath);
      final customMetadata = <String, String>{
        'class_id': widget.classId,
        'topic': widget.topic,
        'quality': _recordingQuality,
        'width': '$_recordingWidth',
        'height': '$_recordingHeight',
        'max_frame_rate': '$_recordingMaxFrameRate',
        'live_bandwidth_kbps': '${_callVideoMaxBitrate ~/ 1000}',
        'target_kb_per_minute': '$_recordingTargetKbPerMinute',
      };
      customMetadata['uploaded_by_uid'] = authUid;

      await updateRecordedClass(<String, dynamic>{
        'upload_status': 'uploading',
        'storage_path': storagePath,
        'file_size_bytes': fileSizeBytes,
      });

      final metadata = SettableMetadata(
        contentType: recordedMime,
        customMetadata: customMetadata,
      );

      try {
        final snapshot = await storageRef
            .putData(_webRecordedBytes!, metadata)
            .timeout(_uploadTimeout);
        if (snapshot.state == TaskState.success) {
          videoUrl = await storageRef.getDownloadURL().timeout(
            const Duration(seconds: 30),
          );
          uploadStatus = 'ready';
          debugPrint('Video uploaded to Storage: $videoUrl');
          _webRecordedBytes = null;
          await updateRecordedClass(<String, dynamic>{
            'video_url': videoUrl,
            'upload_status': uploadStatus,
            'storage_path': storagePath,
            'mime_type': recordedMime,
          });
          return true;
        } else {
          await markRecordingFailed(
            'upload_failed',
            'Storage upload task failed.',
          );
          return false;
        }
      } catch (e) {
        await markRecordingFailed('upload_failed', e.toString());
        return false;
      }
    } else if (videoPath != null) {
      final file = File(videoPath);
      if (await file.exists()) {
        try {
          fileSizeBytes = await file.length();
          if (fileSizeBytes == 0) {
            debugPrint('Recording upload skipped: empty file at $videoPath');
            await markRecordingFailed('empty_file', 'Recorded file was empty.');
            return false;
          } else {
            final authUid = await FirebaseUploadAuthService.ensureSignedIn();
            if (authUid == null) {
              await markRecordingFailed(
                'auth_failed',
                'Firebase Anonymous Authentication is not enabled or sign-in failed. Enable Authentication > Sign-in method > Anonymous in Firebase Console.',
              );
              return false;
            }

            if (mounted) {
              setState(() => _statusMessage = 'Uploading video...');
            }

            storagePath =
                'recorded_classes/${widget.classId}/${recordedAt}_360p_1mbpm.mp4';
            final storageRef = FirebaseStorage.instance.ref().child(
              storagePath,
            );
            final customMetadata = <String, String>{
              'class_id': widget.classId,
              'topic': widget.topic,
              'quality': _recordingQuality,
              'width': '$_recordingWidth',
              'height': '$_recordingHeight',
              'max_frame_rate': '$_recordingMaxFrameRate',
              'live_bandwidth_kbps': '${_callVideoMaxBitrate ~/ 1000}',
              'target_kb_per_minute': '$_recordingTargetKbPerMinute',
            };
            customMetadata['uploaded_by_uid'] = authUid;

            await updateRecordedClass(<String, dynamic>{
              'upload_status': 'uploading',
              'storage_path': storagePath,
              'file_size_bytes': fileSizeBytes,
            });

            final metadata = SettableMetadata(
              contentType: 'video/mp4',
              customMetadata: customMetadata,
            );

            final snapshot = await storageRef
                .putFile(file, metadata)
                .timeout(_uploadTimeout);
            if (snapshot.state == TaskState.success) {
              videoUrl = await storageRef.getDownloadURL().timeout(
                const Duration(seconds: 30),
              );
              uploadStatus = 'ready';
              debugPrint('Video uploaded to Storage: $videoUrl');
              await updateRecordedClass(<String, dynamic>{
                'upload_status': uploadStatus,
                'video_url': videoUrl,
                'storage_path': storagePath,
                'file_size_bytes': fileSizeBytes,
                'upload_error': null,
                'mime_type': 'video/mp4',
              });

              try {
                await file.delete();
              } catch (_) {}
              return true;
            } else {
              final error =
                  'Upload finished with state ${snapshot.state.name}.';
              debugPrint('Recording upload failed: $error');
              await markRecordingFailed('failed', error);
              return false;
            }
          }
        } on TimeoutException catch (e) {
          final error =
              'Video upload timed out after ${_uploadTimeout.inMinutes} minutes: $e';
          debugPrint('Recording upload failed: $error');
          await markRecordingFailed('timeout', error);
          return false;
        } on FirebaseException catch (e) {
          final error = _formatFirebaseStorageError(e);
          debugPrint('Recording upload failed: $error');
          await markRecordingFailed('failed', error);
          return false;
        } catch (e) {
          final error = 'Video upload failed: $e';
          debugPrint('Recording upload failed: $error');
          await markRecordingFailed('failed', error);
          return false;
        }
      } else {
        debugPrint('Recording upload skipped: file not found at $videoPath');
        await markRecordingFailed(
          'missing_file',
          'Recorded file was not found.',
        );
        return false;
      }
    } else {
      await markRecordingFailed(
        'not_recorded',
        'No recording path was created.',
      );
      return false;
    }
  }

  String _formatFirebaseStorageError(FirebaseException error) {
    final details = <String>[
      '[${error.plugin}/${error.code}]',
      if (error.message != null && error.message!.trim().isNotEmpty)
        error.message!.trim(),
    ];

    if (error.plugin == 'firebase_storage' &&
        (error.code == 'unknown' || error.code == 'unauthorized')) {
      details.add(
        'Check that the project is on an active Blaze billing plan, Firebase Storage is enabled, Anonymous Authentication is enabled, and Storage rules allow authenticated mp4 uploads.',
      );
    }

    return details.join(' ');
  }

  Future<void> _closeAllPeerSessions({required bool removeSignals}) async {
    for (final peerId in List<String>.from(_peerSessions.keys)) {
      await _closePeerSession(peerId, removeSignals: removeSignals);
    }
  }

  Future<void> _closePeerSession(
    String peerId, {
    required bool removeSignals,
  }) async {
    final session = _peerSessions.remove(peerId);
    if (session == null) {
      return;
    }

    await session.close();

    if (removeSignals) {
      try {
        await _peerSignalRef(peerId).remove();
      } catch (error, stackTrace) {
        _reportNonFatalError('remove peer signaling', error, stackTrace);
      }
    }

    final renderer = _remoteRenderers.remove(peerId);
    if (renderer != null) {
      try {
        renderer.srcObject = null;
        await renderer.dispose();
      } catch (error, stackTrace) {
        _reportNonFatalError('dispose remote renderer', error, stackTrace);
      }
    }

    if (!mounted || _isCleaningUp || _hasEndedCall) {
      return;
    }

    setState(() {
      if (_focusedRemotePeerId == peerId) {
        _focusedRemotePeerId = _firstConnectedRemotePeerId;
      }
      _isRemoteConnected = _connectedRemoteCount > 0;
      if (!_isRemoteConnected && widget.isTeacher) {
        _statusMessage = 'Waiting for students to join...';
      }
    });
  }

  Future<void> _cleanupRoomState({required bool removeLiveClass}) async {
    if (_isCleaningUp) {
      return;
    }

    _isCleaningUp = true;
    final shouldMutateRoom = _hasClaimedSession;

    try {
      _stopLoopbackConnection();
      // 1. Cancel all Firebase listeners first
      await _participantsSub?.cancel();
      _participantsSub = null;
      await _classStatusSub?.cancel();
      _classStatusSub = null;

      // 2. Remove room state from database
      if (shouldMutateRoom) {
        if (removeLiveClass) {
          await _liveClassRef.remove();
        } else {
          await _participantsRef.child(_localParticipantId).remove();
          if (!widget.isTeacher) {
            await _peerSignalRef(_localParticipantId).remove();
            await _webrtcRef.child('status').set('waiting_for_students');
          }
        }
      }

      // 3. Detach renderer sources BEFORE stopping tracks
      //    (prevents rendering dead/closing tracks → native crash)
      if (_renderersInitialized) {
        _localRenderer.srcObject = null;
        for (final renderer in _remoteRenderers.values) {
          renderer.srcObject = null;
        }
      }

      // 4. Stop all local tracks (releases camera & mic)
      for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        try {
          track.stop();
        } catch (e) {
          debugPrint('Track stop error: $e');
        }
      }
      try {
        _localStream?.dispose();
      } catch (e) {
        debugPrint('Stream dispose error: $e');
      }
      _localStream = null;
      _localAudioTrack = null;
      _localVideoTrack = null;

      // Small delay to let native camera fully release
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 5. Close peer connections (tracks already stopped, safe now)
      await _closeAllPeerSessions(removeSignals: false);

      // 6. Dispose renderers (sources already null, safe to dispose)
      if (_renderersInitialized) {
        try {
          await _localRenderer.dispose();
        } catch (e) {
          debugPrint('Local renderer dispose error: $e');
        }
        try {
          for (final renderer in _remoteRenderers.values) {
            await renderer.dispose();
          }
          _remoteRenderers.clear();
        } catch (e) {
          debugPrint('Remote renderers dispose error: $e');
        }
        _renderersInitialized = false;
      }

      if (WebRTC.platformIsAndroid) {
        try {
          await Helper.clearAndroidCommunicationDevice();
        } catch (e) {
          debugPrint('clearAndroidCommunicationDevice error: $e');
        }
      }
    } catch (error, stackTrace) {
      _reportNonFatalError('cleanup room state', error, stackTrace);
    } finally {
      _releaseSession();
    }
  }

  void _reportNonFatalError(
    String scope,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    debugPrint('LiveVideoRoomPage[$_sessionKey] $scope error: $error');
    if (stackTrace != null) {
      debugPrintStack(
        label: 'LiveVideoRoomPage[$_sessionKey] $scope stack',
        stackTrace: stackTrace,
      );
    }
  }

  bool get _hasRemoteParticipant {
    return _participants.any(
      (participant) => participant['role'] == _remoteRole,
    );
  }

  int get _connectedRemoteCount {
    return _remoteRenderers.values
        .where((renderer) => renderer.srcObject != null)
        .length;
  }

  List<MapEntry<String, RTCVideoRenderer>> get _connectedRemoteRenderers {
    return _remoteRenderers.entries
        .where((entry) => entry.value.srcObject != null)
        .toList();
  }

  String? get _firstConnectedRemotePeerId {
    final connected = _connectedRemoteRenderers;
    if (connected.isEmpty) {
      return null;
    }

    return connected.first.key;
  }

  String _connectedStatusMessage() {
    if (!widget.isTeacher) {
      return 'Live call connected';
    }

    final count = _connectedRemoteCount;
    if (count == 1) {
      return '1 student connected';
    }
    return '$count students connected';
  }

  bool get _hasPendingRecording => _isRecording || _localVideoPath != null;

  bool get _canStartRecording {
    return widget.isTeacher &&
        !_isRecording &&
        !_isSavingRecording &&
        _localStream != null &&
        _localVideoTrack != null &&
        _localVideoPath == null;
  }

  bool get _canSaveRecording {
    return widget.isTeacher && !_isSavingRecording && _hasPendingRecording;
  }

  String _buildRecordingDurationText(DateTime? startedAt) {
    if (startedAt == null) {
      return '0 mins';
    }

    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed.inHours > 0) {
      return '${elapsed.inHours}h ${elapsed.inMinutes.remainder(60)}m';
    }
    if (elapsed.inMinutes > 0) {
      return '${elapsed.inMinutes} mins';
    }
    return '${max(1, elapsed.inSeconds)} sec';
  }

  String _formattedRecordingTime() {
    if (_recordingStartTime == null) return '00:00';
    final duration = DateTime.now().difference(_recordingStartTime!);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _toggleSpeaker() async {
    final nextVal = !_isSpeakerOn;
    if (kIsWeb) {
      setState(() {
        _isSpeakerOn = nextVal;
      });
      for (final renderer in _remoteRenderers.values) {
        renderer.volume = nextVal ? 1.0 : 0.15;
      }
      _showSnackBar(nextVal ? 'Volume set to high' : 'Volume set to normal');
    } else {
      try {
        await Helper.setSpeakerphoneOn(nextVal);
        setState(() {
          _isSpeakerOn = nextVal;
        });
        _showSnackBar(nextVal ? 'Speakerphone turned on' : 'Earpiece turned on');
      } catch (e) {
        debugPrint('Failed to toggle speakerphone: $e');
      }
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  int? _parseInt(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    unawaited(_disableScreenAwake());
    if (!_hasEndedCall) {
      unawaited(_cleanupRoomState(removeLiveClass: widget.isTeacher));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_endCall());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(
                    () => _showOwnCameraSmall = !_showOwnCameraSmall,
                  ),
                  child: Container(
                    color: const Color(0xFF1C1C1E),
                    child: _buildMainVideoPanel(),
                  ),
                ),
              ),
              Positioned(
                top: 20,
                left: 20,
                right: 20,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'LIVE',
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          if (_isRecording) ...[
                            const SizedBox(width: 8),
                            Container(
                              width: 1,
                              height: 12,
                              color: Colors.white24,
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.fiber_manual_record,
                              color: Colors.red,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'REC ${_formattedRecordingTime()}',
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.only(left: 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          widget.topic,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_buildPipContent() != null)
                Positioned(
                  bottom: 120,
                  right: _isPipOnRight ? 20 : null,
                  left: !_isPipOnRight ? 20 : null,
                  child: GestureDetector(
                    onPanUpdate: (details) {
                      setState(() {
                        _isPipOnRight =
                            details.globalPosition.dx >
                            MediaQuery.of(context).size.width / 2;
                      });
                    },
                    onTap: () => setState(
                      () => _showOwnCameraSmall = !_showOwnCameraSmall,
                    ),
                    child: Container(
                      width: 120,
                      height: 180,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                          width: 2,
                        ),
                        boxShadow: const [
                          BoxShadow(color: Colors.black54, blurRadius: 15),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: _buildPipContent(),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 80,
                right: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (_localVideoTrack != null)
                      GestureDetector(
                        onTap: () => unawaited(_switchCamera()),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white12),
                          ),
                          child: const Icon(
                            Icons.flip_camera_ios_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.people_rounded,
                            color: Colors.white70,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_participants.length} Active',
                            style: GoogleFonts.poppins(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: 30,
                left: 0,
                right: 0,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 14,
                  runSpacing: 12,
                  children: [
                    if (widget.isTeacher)
                      _buildControlButton(
                        tooltip: _isRecording
                            ? 'Recording in progress'
                            : 'Start recording',
                        icon: Icons.fiber_manual_record_rounded,
                        color: _isRecording
                            ? Colors.redAccent
                            : Colors.white.withValues(alpha: 0.2),
                        iconColor: _isRecording
                            ? Colors.white
                            : Colors.redAccent,
                        enabled: _canStartRecording,
                        dimWhenDisabled: !_isRecording,
                        onTap: _startRecording,
                      ),
                    _buildControlButton(
                      tooltip: _isSpeakerOn
                          ? 'Switch to earpiece'
                          : 'Switch to speaker',
                      icon: _isSpeakerOn
                          ? Icons.volume_up_rounded
                          : Icons.volume_down_rounded,
                      color: _isSpeakerOn
                          ? Colors.white.withValues(alpha: 0.2)
                          : Colors.redAccent,
                      iconColor: Colors.white,
                      onTap: _toggleSpeaker,
                    ),
                    _buildControlButton(
                      tooltip: _isMicMuted ? 'Unmute mic' : 'Mute mic',
                      icon: _isMicMuted
                          ? Icons.mic_off_rounded
                          : Icons.mic_rounded,
                      color: _isMicMuted
                          ? Colors.redAccent
                          : Colors.white.withValues(alpha: 0.2),
                      iconColor: Colors.white,
                      onTap: _toggleMic,
                    ),
                    _buildControlButton(
                      tooltip: 'End call',
                      icon: Icons.call_end_rounded,
                      color: Colors.redAccent,
                      iconColor: Colors.white,
                      size: 64,
                      onTap: _endCall,
                    ),
                    _buildControlButton(
                      tooltip: _isVideoOff
                          ? 'Turn camera on'
                          : 'Turn camera off',
                      icon: _isVideoOff
                          ? Icons.videocam_off_rounded
                          : Icons.videocam_rounded,
                      color: _isVideoOff
                          ? Colors.redAccent
                          : Colors.white.withValues(alpha: 0.2),
                      iconColor: Colors.white,
                      onTap: _toggleVideo,
                    ),
                    if (widget.isTeacher)
                      _buildControlButton(
                        tooltip: _isSavingRecording
                            ? 'Saving recording'
                            : 'Save recording',
                        icon: Icons.save_rounded,
                        color: const Color(0xFF1F7A4D),
                        iconColor: Colors.white,
                        enabled: _canSaveRecording,
                        onTap: _saveRecordingNow,
                      ),
                  ],
                ),
              ),
              if (_isProcessing)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.8),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                            const SizedBox(height: 24),
                            Text(
                              'Please Wait',
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _statusMessage,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainVideoPanel() {
    final showLocalInMain = !_showOwnCameraSmall;

    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (!_renderersInitialized) {
      return _buildRemotePlaceholder();
    }

    if (showLocalInMain) {
      return _buildLocalVideoView(expanded: true);
    }

    if (_isRemoteConnected) {
      return _buildRemoteVideoArea();
    }

    return _buildRemotePlaceholder();
  }

  Widget? _buildPipContent() {
    if (_isInitializing || !_renderersInitialized) {
      return null;
    }

    final showLocalInPip = _showOwnCameraSmall;

    if (showLocalInPip) {
      return _buildLocalVideoView(expanded: false);
    }

    if (_isRemoteConnected) {
      return _buildRemoteThumbnail();
    }

    return Center(
      child: Icon(
        widget.isTeacher ? Icons.school_rounded : Icons.person_rounded,
        color: Colors.white24,
        size: 36,
      ),
    );
  }

  Widget _buildRemoteVideoArea() {
    final connectedRenderers = _connectedRemoteRenderers;
    if (connectedRenderers.isEmpty) {
      return _buildRemotePlaceholder();
    }

    if (!widget.isTeacher || connectedRenderers.length == 1) {
      final focusedEntry = _focusedRemoteEntry ?? connectedRenderers.first;
      return RTCVideoView(focusedEntry.value);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900 ? 3 : 2;
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 16 / 9,
          ),
          itemCount: connectedRenderers.length,
          itemBuilder: (context, index) {
            final entry = connectedRenderers[index];
            return GestureDetector(
              onTap: () => setState(() => _focusedRemotePeerId = entry.key),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      color: const Color(0xFF111111),
                      child: RTCVideoView(entry.value),
                    ),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _remoteParticipantName(entry.key),
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRemoteThumbnail() {
    final focusedEntry = _focusedRemoteEntry;
    if (focusedEntry == null) {
      return Center(
        child: Icon(
          widget.isTeacher ? Icons.school_rounded : Icons.person_rounded,
          color: Colors.white24,
          size: 36,
        ),
      );
    }

    return RTCVideoView(focusedEntry.value);
  }

  MapEntry<String, RTCVideoRenderer>? get _focusedRemoteEntry {
    final connectedRenderers = _connectedRemoteRenderers;
    if (connectedRenderers.isEmpty) {
      return null;
    }

    final focusedPeerId = _focusedRemotePeerId;
    if (focusedPeerId != null) {
      for (final entry in connectedRenderers) {
        if (entry.key == focusedPeerId) {
          return entry;
        }
      }
    }

    return connectedRenderers.first;
  }

  String _remoteParticipantName(String peerId) {
    for (final participant in _participants) {
      if (participant['id']?.toString() == peerId) {
        final name = participant['name']?.toString();
        if (name != null && name.isNotEmpty) {
          return name;
        }
      }
    }

    return widget.isTeacher ? 'Student' : 'Teacher';
  }

  Widget _buildLocalVideoView({required bool expanded}) {
    if (!_renderersInitialized ||
        _isVideoOff ||
        _localRenderer.srcObject == null) {
      return _buildLocalPlaceholder(expanded: expanded);
    }

    return RTCVideoView(_localRenderer, mirror: _isFrontCamera);
  }

  Widget _buildLocalPlaceholder({required bool expanded}) {
    return Container(
      color: const Color(0xFF2C2C2E),
      child: Center(
        child: Icon(
          Icons.person_rounded,
          color: Colors.white24,
          size: expanded ? 64 : 36,
        ),
      ),
    );
  }

  Widget _buildRemotePlaceholder() {
    final statusText = (_errorMessage != null && _errorMessage!.isNotEmpty)
        ? _errorMessage!
        : (_statusMessage.isNotEmpty
              ? _statusMessage
              : (widget.isTeacher
                    ? 'Waiting for student feeds...'
                    : 'Connecting to ${widget.topic}...'));

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.primaryNavy.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.primaryNavy.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: Icon(
              widget.isTeacher ? Icons.school_rounded : Icons.person_rounded,
              size: 60,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            statusText,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (!widget.isTeacher)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Teacher is live',
                style: GoogleFonts.poppins(
                  color: Colors.greenAccent.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    required Color iconColor,
    required Future<void> Function() onTap,
    double size = 56,
    bool enabled = true,
    bool dimWhenDisabled = true,
  }) {
    final useDisabledStyle = !enabled && dimWhenDisabled;
    final effectiveColor = useDisabledStyle
        ? Colors.white.withValues(alpha: 0.12)
        : color;
    final effectiveIconColor = useDisabledStyle ? Colors.white38 : iconColor;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: GestureDetector(
          onTap: enabled ? () => unawaited(onTap()) : null,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: effectiveColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: effectiveIconColor, size: size * 0.5),
          ),
        ),
      ),
    );
  }
}

class _PeerSession {
  _PeerSession({required this.peerId});

  final String peerId;
  final Set<String> processedRemoteCandidateKeys = <String>{};
  final List<RTCIceCandidate> pendingRemoteCandidates = <RTCIceCandidate>[];

  RTCPeerConnection? connection;
  RTCRtpSender? localAudioSender;
  RTCRtpSender? localVideoSender;
  StreamSubscription<DatabaseEvent>? offerSub;
  StreamSubscription<DatabaseEvent>? answerSub;
  StreamSubscription<DatabaseEvent>? remoteCandidatesSub;

  bool remoteDescriptionApplied = false;
  bool isClosing = false;

  Future<void> close() async {
    if (isClosing) {
      return;
    }

    isClosing = true;
    await offerSub?.cancel();
    offerSub = null;
    await answerSub?.cancel();
    answerSub = null;
    await remoteCandidatesSub?.cancel();
    remoteCandidatesSub = null;

    try {
      await connection?.close();
    } catch (error) {
      debugPrint('PeerConnection close error: $error');
    }

    connection = null;
    localAudioSender = null;
    localVideoSender = null;
    pendingRemoteCandidates.clear();
    processedRemoteCandidateKeys.clear();
  }
}
