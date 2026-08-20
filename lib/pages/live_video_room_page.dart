import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/web_recording_helper.dart';

import '../services/firebase_upload_auth_service.dart';
import '../services/live_class_lifecycle_policy.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../components/universal_image.dart';
import '../components/web_pdf_page_view.dart';
import '../services/web_pdf_renderer.dart';

class LiveVideoRoomPage extends StatefulWidget {
  static final Set<String> _activeSessionKeys = <String>{};

  final bool isTeacher;
  final String classId;
  final String topic;
  final String? subjectId;
  final String? participantId;
  final String? participantName;
  final MediaStream? initialLocalStream;

  const LiveVideoRoomPage({
    super.key,
    required this.isTeacher,
    required this.classId,
    required this.topic,
    this.subjectId,
    this.participantId,
    this.participantName,
    this.initialLocalStream,
  });

  @override
  State<LiveVideoRoomPage> createState() => _LiveVideoRoomPageState();
}

class _LiveVideoRoomPageState extends State<LiveVideoRoomPage>
    with WidgetsBindingObserver {
  static const MethodChannel _audioOutputChannel = MethodChannel(
    'com.academy.scholars/audio_output',
  );
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
  static const Duration _uploadRetryLimit = Duration(minutes: 30);
  static const Duration _studentReconnectDelay = Duration(seconds: 2);
  static const Duration _studentConnectTimeout = Duration(seconds: 12);
  static const Duration _participantHeartbeatInterval = Duration(seconds: 30);
  static const Duration _classEndConfirmationDelay = Duration(seconds: 5);
  static const int _maxStudentReconnectAttempts = 3;
  static const int _maxSharedPdfBytes = 100 * 1024 * 1024;
  static const Map<String, dynamic> _preferredWebAudioConstraints =
      <String, dynamic>{
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'channelCount': 1,
      };

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers =
      <String, RTCVideoRenderer>{};
  final Map<String, Future<RTCVideoRenderer?>> _remoteRendererInitializations =
      <String, Future<RTCVideoRenderer?>>{};
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
  StreamSubscription<DatabaseEvent>? _firebaseConnectionSub;

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
  final List<Map<String, dynamic>> _recordingPresentationEvents =
      <Map<String, dynamic>>[];
  String? _lastRecordedPresentationState;
  bool _isSpeakerOn = true;
  bool _webAudioUnlocked = !kIsWeb;
  Timer? _recordingTimer;
  Timer? _studentReconnectTimer;
  Timer? _participantHeartbeatTimer;
  Timer? _classEndConfirmationTimer;
  int _studentReconnectAttempts = 0;
  bool _studentReconnectInProgress = false;
  bool _showStudentReconnectAction = false;
  bool _firebaseConnectionInitialized = false;
  bool _firebaseWasDisconnected = false;
  bool _connectivityRecoveryInProgress = false;
  bool _presenceRefreshInProgress = false;
  RTCPeerConnection? _loopbackConnectionA;
  RTCPeerConnection? _loopbackConnectionB;
  dynamic _webRecordedBlob;
  final _webRecordingHelper = WebRecordingHelper();

  String _statusMessage = '';
  String? _errorMessage;
  String? _focusedRemotePeerId;
  late String _localParticipantId;
  late String _localParticipantName;
  late String _connectionId;

  List<Map<String, dynamic>> _participants = <Map<String, dynamic>>[];

  // Shared Document & Whiteboard State
  StreamSubscription<DatabaseEvent>? _drawingStrokesSub;
  StreamSubscription<DatabaseEvent>? _currentStrokeSub;
  StreamSubscription<DatabaseEvent>? _sharedDocumentSub;

  List<DrawingStroke> _completedStrokes = [];
  DrawingStroke? _currentStroke;

  String? _sharedDocUrl;
  String? _sharedDocName;
  String? _sharedDocType;
  int _sharedDocPage = 1;
  int _sharedDocPageCount = 0;
  int _pdfReloadNonce = 0;
  PdfDocumentRef? _sharedPdfDocumentRef;
  final TransformationController _documentTransformationController =
      TransformationController();
  double _documentZoom = 1.0;
  bool _isDocumentFullScreen = false;
  Future<void> _pdfPageSyncTask = Future<void>.value();
  bool _isDrawingMode = false;
  bool _isSharedDocumentPickerOpen = false;
  bool _isExitConfirmationOpen = false;
  DateTime? _ignoreBackNavigationUntil;
  Color _selectedDrawColor = Colors.red;
  double _selectedDrawWidth = 4.0;
  int _lastSyncTime = 0;
  List<Offset> _activePoints = [];
  PlatformFile? _localSharedFile;
  bool _showWhiteboardToolbar = true;
  final GlobalKey _canvasKey = GlobalKey();
  bool get _isStudentDocumentFullScreen =>
      !widget.isTeacher && _sharedDocUrl != null && _isDocumentFullScreen;

  DatabaseReference get _liveClassRef => FirebaseDatabase.instance
      .ref()
      .child('live_classes')
      .child(widget.classId);

  DatabaseReference get _participantsRef => _liveClassRef.child('participants');

  DatabaseReference get _webrtcRef => _liveClassRef.child('webrtc');

  String get _localRole => widget.isTeacher ? 'teacher' : 'student';

  String get _remoteRole => widget.isTeacher ? 'student' : 'teacher';

  String get _sessionKey =>
      '$_localRole:${widget.classId}:$_localParticipantId';

  DatabaseReference _sessionSignalRef(String peerId) {
    if (widget.isTeacher) {
      return _webrtcRef.child('peers').child(peerId);
    }
    if (peerId == _localParticipantId) {
      return _webrtcRef.child('peers').child(_localParticipantId);
    }
    final sorted = [_localParticipantId, peerId]..sort();
    return _webrtcRef.child('peers').child('${sorted[0]}_${sorted[1]}');
  }

  String _sessionLocalSignalRole(String peerId) {
    if (widget.isTeacher) {
      return 'teacher';
    }
    if (peerId == _localParticipantId) {
      return 'student';
    }
    final isOfferer = _localParticipantId.compareTo(peerId) < 0;
    return isOfferer ? 'offerer' : 'answerer';
  }

  String _sessionRemoteSignalRole(String peerId) {
    if (widget.isTeacher) {
      return 'student';
    }
    if (peerId == _localParticipantId) {
      return 'teacher';
    }
    final isOfferer = _localParticipantId.compareTo(peerId) < 0;
    return isOfferer ? 'answerer' : 'offerer';
  }

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
    WidgetsBinding.instance.addObserver(this);
    _localParticipantId = _buildLocalParticipantId();
    _localParticipantName = _buildLocalParticipantName();
    _connectionId = _buildConnectionId();
    _callStartedAt = DateTime.now();
    _localStream = widget.initialLocalStream;
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
        'student_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1 << 30)}';
    return _sanitizeFirebaseKey(fallbackId);
  }

  String _buildLocalParticipantName() {
    final providedName = widget.participantName?.trim();
    if (providedName != null && providedName.isNotEmpty) {
      return providedName;
    }

    return widget.isTeacher ? 'Teacher' : 'Student';
  }

  String _buildConnectionId() {
    return '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';
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
      if (widget.isTeacher) {
        LiveVideoRoomPage._activeSessionKeys.remove(_sessionKey);
      } else {
        return false;
      }
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
    if (kIsWeb) return;
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

      final granted =
          _localStream != null || await PermissionService.requestCameraAndMic();
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

      if (!widget.isTeacher) {
        // A returning student reuses the same participant ID. Remove the old
        // offer/answer/candidates before advertising the new connection.
        await _sessionSignalRef(_localParticipantId).remove();
      }

      if (!WebRTC.platformIsWeb) {
        // Delay slightly to ensure AudioSwitchManager is active/started,
        // then force speakerphone and maximum call volume by default.
        Future.delayed(const Duration(milliseconds: 500), () async {
          await _maximizeAndroidSpeakerVolume();
        });
      }
      _listenToParticipants();
      await _registerParticipant();
      _startParticipantHeartbeat();
      _listenForFirebaseConnectionChanges();
      _listenForSignaling();
      if (!widget.isTeacher) {
        _listenForClassStatus();
      }
      _listenForSharedWhiteboard();

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
      await _failAndClose(_friendlyCallStartError(error));
    }
  }

  String _friendlyCallStartError(Object error) {
    final normalized = error.toString().toLowerCase();
    if (normalized.contains('notallowederror') ||
        normalized.contains('permission') ||
        normalized.contains('denied')) {
      return 'Camera or microphone access is blocked. Allow both permissions and try again.';
    }
    if (normalized.contains('notfounderror') ||
        normalized.contains('devicesnotfound') ||
        normalized.contains('no camera')) {
      return 'No available camera or microphone was found on this device.';
    }
    if (normalized.contains('notreadableerror') ||
        normalized.contains('trackstarterror')) {
      return 'The camera or microphone is being used by another app. Close it and try again.';
    }
    return 'Unable to start the live class. Please check your connection and try again.';
  }

  Future<void> _registerParticipant() async {
    try {
      final participantRef = _participantsRef.child(_localParticipantId);

      await participantRef.onDisconnect().remove();
      await participantRef.set(<String, dynamic>{
        'id': _localParticipantId,
        'name': _localParticipantName,
        'role': _localRole,
        'connection_id': _connectionId,
        'joined_at': ServerValue.timestamp,
        'last_seen': ServerValue.timestamp,
        'mic_enabled': !_isMicMuted,
        'video_enabled': !_isVideoOff,
      });
    } catch (error, stackTrace) {
      _reportNonFatalError('register participant', error, stackTrace);
    }
  }

  void _startParticipantHeartbeat() {
    _participantHeartbeatTimer?.cancel();
    _participantHeartbeatTimer = Timer.periodic(
      _participantHeartbeatInterval,
      (_) => unawaited(_refreshParticipantPresence()),
    );
  }

  Future<bool> _isFirebaseConnected() async {
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref('.info/connected')
          .get();
      return snapshot.value == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isTeacherClassLive() async {
    try {
      final snapshot = await _liveClassRef.child('is_live').get();
      return snapshot.value == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshParticipantPresence() async {
    if (_hasEndedCall ||
        _isCleaningUp ||
        !_hasClaimedSession ||
        _presenceRefreshInProgress) {
      return;
    }

    _presenceRefreshInProgress = true;
    try {
      if (!await _isFirebaseConnected()) {
        return;
      }
      if (!widget.isTeacher && !await _isTeacherClassLive()) {
        _scheduleClassEndConfirmation();
        return;
      }

      final participantRef = _participantsRef.child(_localParticipantId);
      // Firebase onDisconnect operations fire once. Re-arm it whenever the
      // connection is healthy so a later Android network switch is handled.
      await participantRef.onDisconnect().remove();
      await participantRef.runTransaction((currentValue) {
        if (currentValue is Map) {
          final currentConnectionId = currentValue['connection_id']?.toString();
          if (currentConnectionId != null &&
              currentConnectionId.isNotEmpty &&
              currentConnectionId != _connectionId) {
            return Transaction.abort();
          }
        }

        final presence = currentValue is Map
            ? Map<String, dynamic>.from(currentValue)
            : <String, dynamic>{};
        presence.addAll(<String, dynamic>{
          'id': _localParticipantId,
          'name': _localParticipantName,
          'role': _localRole,
          'connection_id': _connectionId,
          'last_seen': ServerValue.timestamp,
          'mic_enabled': !_isMicMuted,
          'video_enabled': !_isVideoOff,
        });
        presence['joined_at'] ??= ServerValue.timestamp;
        return Transaction.success(presence);
      });
    } catch (error) {
      // A heartbeat is best-effort. The Firebase connection listener and the
      // next heartbeat will retry without closing the live room.
      debugPrint('Participant presence refresh failed: $error');
    } finally {
      _presenceRefreshInProgress = false;
    }
  }

  void _listenForFirebaseConnectionChanges() {
    _firebaseConnectionSub?.cancel();
    _firebaseConnectionSub = FirebaseDatabase.instance
        .ref('.info/connected')
        .onValue
        .listen(
          (event) {
            final connected = event.snapshot.value == true;
            if (!_firebaseConnectionInitialized) {
              _firebaseConnectionInitialized = true;
              _firebaseWasDisconnected = !connected;
              return;
            }

            if (!connected) {
              _firebaseWasDisconnected = true;
              if (mounted && !widget.isTeacher && !_hasEndedCall) {
                _updateStatus('Connection interrupted. Reconnecting...');
              }
              return;
            }

            if (_firebaseWasDisconnected) {
              _firebaseWasDisconnected = false;
              unawaited(_recoverAfterConnectivityReturns());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _reportNonFatalError(
              'Firebase connectivity listener',
              error,
              stackTrace,
            );
          },
        );
  }

  Future<void> _recoverAfterConnectivityReturns() async {
    if (_connectivityRecoveryInProgress ||
        _isInitializing ||
        _hasEndedCall ||
        _isCleaningUp) {
      return;
    }

    _connectivityRecoveryInProgress = true;
    try {
      if (!widget.isTeacher && !await _isTeacherClassLive()) {
        _scheduleClassEndConfirmation();
        return;
      }

      await _refreshParticipantPresence();
      if (!widget.isTeacher && !_isStudentTeacherConnected) {
        await _restartStudentConnection(manual: true);
      }
    } finally {
      _connectivityRecoveryInProgress = false;
    }
  }

  Future<void> _removeParticipantRegistrationIfCurrent() async {
    final participantRef = _participantsRef.child(_localParticipantId);
    await participantRef.runTransaction((currentValue) {
      if (currentValue is Map) {
        final currentConnectionId = currentValue['connection_id']?.toString();
        if (currentConnectionId != null &&
            currentConnectionId.isNotEmpty &&
            currentConnectionId != _connectionId) {
          return Transaction.abort();
        }
      }
      return Transaction.success(null);
    });
  }

  Future<void> _removeStudentSignalsIfCurrent() async {
    final signalRef = _sessionSignalRef(_localParticipantId);
    await signalRef.runTransaction((currentValue) {
      if (currentValue is Map) {
        final offer = currentValue['offer'];
        if (offer is Map) {
          final receiverConnectionId = offer['receiver_connection_id']
              ?.toString();
          if (receiverConnectionId != null &&
              receiverConnectionId.isNotEmpty &&
              receiverConnectionId != _connectionId) {
            return Transaction.abort();
          }
        }
      }
      return Transaction.success(null);
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
        } else {
          unawaited(_syncStudentStudentPeers(participants));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _reportNonFatalError('participants listener', error, stackTrace);
      },
    );
  }

  Future<void> _setupLocalMedia() async {
    if (_localStream == null) {
      if (kIsWeb) {
        try {
          _localStream = await navigator.mediaDevices.getUserMedia(
            <String, dynamic>{
              'audio': _preferredWebAudioConstraints,
              'video': <String, dynamic>{
                'width': <String, dynamic>{'ideal': _callVideoWidth},
                'height': <String, dynamic>{'ideal': _callVideoHeight},
                'frameRate': <String, dynamic>{'ideal': _callVideoMaxFrameRate},
                'facingMode': 'user',
              },
            },
          );
        } catch (_) {
          try {
            _localStream = await navigator.mediaDevices.getUserMedia(
              <String, dynamic>{
                'audio': _preferredWebAudioConstraints,
                'video': <String, dynamic>{'facingMode': 'user'},
              },
            );
          } catch (_) {
            _localStream = await navigator.mediaDevices.getUserMedia(
              <String, dynamic>{
                'audio': true,
                'video': true,
              },
            );
          }
        }
      } else {
        final mediaConstraints = <String, dynamic>{
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
        _localStream = await navigator.mediaDevices.getUserMedia(
          mediaConstraints,
        );
      }
    }

    _localAudioTrack = _localStream!.getAudioTracks().isNotEmpty
        ? _localStream!.getAudioTracks().first
        : null;
    _localVideoTrack = _localStream!.getVideoTracks().isNotEmpty
        ? _localStream!.getVideoTracks().first
        : null;
    _localRenderer.srcObject = _localStream;
  }

  Future<_PeerSession> _createPeerSession(
    String peerId, {
    String? remoteConnectionId,
  }) async {
    final existingSession = _peerSessions[peerId];
    if (existingSession != null) {
      return existingSession;
    }

    final localStream = _localStream;
    if (localStream == null) {
      throw StateError('Local media is not ready.');
    }

    final session = _PeerSession(
      peerId: peerId,
      remoteConnectionId: remoteConnectionId,
    );
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
        await _sessionSignalRef(peerId)
            .child('candidates')
            .child(_sessionLocalSignalRole(peerId))
            .push()
            .set(<String, dynamic>{
              'candidate': candidateValue,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
              'sender_connection_id': _connectionId,
              if (session.remoteConnectionId != null)
                'target_connection_id': session.remoteConnectionId,
              'created_at': ServerValue.timestamp,
            });
      } catch (error, stackTrace) {
        _reportNonFatalError('publish local candidate', error, stackTrace);
      }
    };

    peerConnection.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _attachRemoteStream(session, event.streams.first);
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

    final studentConnections = <String, String?>{};
    for (final participant in participants) {
      if (participant['role'] != 'student') continue;
      final studentId = participant['id']?.toString() ?? '';
      if (studentId.isEmpty) continue;
      studentConnections[studentId] = participant['connection_id']?.toString();
    }
    final studentIds = studentConnections.keys.toSet();

    for (final peerId in List<String>.from(_peerSessions.keys)) {
      if (!studentIds.contains(peerId)) {
        await _closePeerSession(peerId, removeSignals: true);
      }
    }

    for (final studentId in studentIds) {
      final connectionId = studentConnections[studentId];
      final existingSession = _peerSessions[studentId];
      if (existingSession != null &&
          connectionId != null &&
          connectionId.isNotEmpty &&
          existingSession.remoteConnectionId != connectionId) {
        debugPrint(
          'Student $studentId rejoined with a new connection. Rebuilding peer.',
        );
        await _closePeerSession(studentId, removeSignals: true);
      }

      if (_peerSessions.containsKey(studentId) ||
          _teacherPeerStartInProgress.contains(studentId)) {
        continue;
      }

      await _startTeacherPeer(studentId, connectionId);
    }
  }

  Future<void> _startTeacherPeer(String studentId, String? connectionId) async {
    _teacherPeerStartInProgress.add(studentId);

    try {
      final session = await _createPeerSession(
        studentId,
        remoteConnectionId: connectionId,
      );
      _listenToRemoteCandidates(session);
      session.answerSub = _sessionSignalRef(studentId)
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
      session.offerSub = _sessionSignalRef(_localParticipantId)
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

  Future<void> _syncStudentStudentPeers(
    List<Map<String, dynamic>> participants,
  ) async {
    if (widget.isTeacher ||
        _hasEndedCall ||
        _isCleaningUp ||
        _localStream == null) {
      return;
    }

    final otherStudentConnections = <String, String?>{};
    for (final participant in participants) {
      final studentId = participant['id']?.toString() ?? '';
      if (participant['role'] != 'student' ||
          studentId.isEmpty ||
          studentId == _localParticipantId) {
        continue;
      }
      otherStudentConnections[studentId] = participant['connection_id']
          ?.toString();
    }
    final otherStudentIds = otherStudentConnections.keys.toSet();

    for (final peerId in List<String>.from(_peerSessions.keys)) {
      if (peerId != _localParticipantId && !otherStudentIds.contains(peerId)) {
        await _closePeerSession(peerId, removeSignals: true);
      }
    }

    for (final studentId in otherStudentIds) {
      final connectionId = otherStudentConnections[studentId];
      final existingSession = _peerSessions[studentId];
      if (existingSession != null &&
          connectionId != null &&
          connectionId.isNotEmpty &&
          existingSession.remoteConnectionId != connectionId) {
        await _closePeerSession(studentId, removeSignals: true);
      }

      if (_peerSessions.containsKey(studentId) ||
          _teacherPeerStartInProgress.contains(studentId)) {
        continue;
      }

      await _startStudentStudentPeer(studentId, connectionId);
    }
  }

  Future<void> _startStudentStudentPeer(
    String studentId,
    String? connectionId,
  ) async {
    _teacherPeerStartInProgress.add(studentId);

    try {
      final session = await _createPeerSession(
        studentId,
        remoteConnectionId: connectionId,
      );
      _listenToRemoteCandidates(session);

      final isOfferer = _localParticipantId.compareTo(studentId) < 0;
      if (isOfferer) {
        session.answerSub = _sessionSignalRef(studentId)
            .child('answer')
            .onValue
            .listen(
              (event) => unawaited(_handleAnswerUpdated(studentId, event)),
              onError: (Object error, StackTrace stackTrace) {
                _reportNonFatalError(
                  'student answer listener',
                  error,
                  stackTrace,
                );
              },
            );

        await _createAndSendOffer(studentId);
      } else {
        session.offerSub = _sessionSignalRef(studentId)
            .child('offer')
            .onValue
            .listen(
              (event) => unawaited(_handleOfferUpdated(studentId, event)),
              onError: (Object error, StackTrace stackTrace) {
                _reportNonFatalError(
                  'student offer listener',
                  error,
                  stackTrace,
                );
              },
            );
      }
    } catch (error, stackTrace) {
      _reportNonFatalError('start student student peer', error, stackTrace);
      await _closePeerSession(studentId, removeSignals: true);
    } finally {
      _teacherPeerStartInProgress.remove(studentId);
    }
  }

  void _listenToRemoteCandidates(_PeerSession session) {
    if (session.remoteCandidatesSub != null) {
      return;
    }

    session.remoteCandidatesSub = _sessionSignalRef(session.peerId)
        .child('candidates')
        .child(_sessionRemoteSignalRole(session.peerId))
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
      unawaited(
        _startStudentPeer().whenComplete(
          () => _scheduleStudentReconnect(delay: _studentConnectTimeout),
        ),
      );
    }
  }

  void _listenForClassStatus() {
    _classStatusSub = _liveClassRef.onValue.listen(
      (event) {
        if (!mounted || widget.isTeacher) return;

        final data = event.snapshot.value;
        if (LiveClassLifecyclePolicy.isActiveSnapshot(data)) {
          _classEndConfirmationTimer?.cancel();
          _classEndConfirmationTimer = null;
          return;
        }

        // A brief Android network handoff can temporarily expose a stale,
        // empty, or incomplete cached snapshot. Confirm every non-live value
        // against the connected server before treating it as a teacher end.
        _scheduleClassEndConfirmation();
      },
      onError: (Object error, StackTrace stackTrace) {
        _reportNonFatalError('class status listener', error, stackTrace);
      },
    );
  }

  void _scheduleClassEndConfirmation() {
    if (widget.isTeacher || _hasEndedCall || _isCleaningUp) {
      return;
    }

    _classEndConfirmationTimer?.cancel();
    _classEndConfirmationTimer = Timer(
      _classEndConfirmationDelay,
      () => unawaited(_confirmTeacherEndedClass()),
    );
  }

  Future<void> _confirmTeacherEndedClass() async {
    if (!mounted || widget.isTeacher || _hasEndedCall || _isCleaningUp) {
      return;
    }

    // Never close a student's room merely because their phone is offline.
    if (!await _isFirebaseConnected()) {
      if (mounted) {
        _updateStatus('Connection interrupted. Reconnecting...');
      }
      return;
    }

    try {
      final snapshot = await _liveClassRef.get();
      final data = snapshot.value;
      final shouldClose = LiveClassLifecyclePolicy.shouldCloseStudentRoom(
        firebaseConnected: true,
        classSnapshot: data,
      );
      if (shouldClose && mounted && !_hasEndedCall && !_isCleaningUp) {
        debugPrint('Teacher end confirmed from Firebase.');
        await _endCall();
      }
    } catch (error, stackTrace) {
      _reportNonFatalError('confirm teacher ended class', error, stackTrace);
    }
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
      final targetConnectionId = candidateMap['target_connection_id']
          ?.toString();
      if (targetConnectionId != null &&
          targetConnectionId.isNotEmpty &&
          targetConnectionId != _connectionId) {
        return;
      }
      final senderConnectionId = candidateMap['sender_connection_id']
          ?.toString();
      if (session.remoteConnectionId != null &&
          senderConnectionId != null &&
          senderConnectionId.isNotEmpty &&
          senderConnectionId != session.remoteConnectionId) {
        return;
      }
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
      final senderConnectionId = answerMap['sender_connection_id']?.toString();
      if (session.remoteConnectionId != null &&
          senderConnectionId != null &&
          senderConnectionId.isNotEmpty &&
          senderConnectionId != session.remoteConnectionId) {
        return;
      }
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
      final receiverConnectionId = offerMap['receiver_connection_id']
          ?.toString();
      if (receiverConnectionId != null &&
          receiverConnectionId.isNotEmpty &&
          receiverConnectionId != _connectionId) {
        return;
      }
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

      await _sessionSignalRef(peerId).child('answer').set(<String, dynamic>{
        'type': answer.type,
        'sdp': answer.sdp,
        'sender_connection_id': _connectionId,
        'created_at': ServerValue.timestamp,
      });

      _updateStatus('Joining live classroom...');
    } catch (error, stackTrace) {
      _reportNonFatalError('apply offer', error, stackTrace);
    }
  }

  Future<void> _resetTeacherSession() async {
    try {
      await _webrtcRef.remove();
      await _participantsRef.remove();
      await _webrtcRef.child('status').set('waiting_for_students');
    } catch (error, stackTrace) {
      _reportNonFatalError('reset teacher session', error, stackTrace);
    }
  }

  Future<void> _createAndSendOffer(String peerId) async {
    final session = _peerSessions[peerId];
    final peerConnection = session?.connection;
    if (session == null || session.isClosing || peerConnection == null) {
      return;
    }

    final offer = await peerConnection.createOffer(_sdpConstraints);
    await peerConnection.setLocalDescription(offer);

    await _sessionSignalRef(peerId).child('offer').set(<String, dynamic>{
      'type': offer.type,
      'sdp': offer.sdp,
      if (session.remoteConnectionId != null)
        'receiver_connection_id': session.remoteConnectionId,
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

  void _attachRemoteStream(_PeerSession session, MediaStream stream) {
    unawaited(_attachRemoteStreamInternal(session, stream));
  }

  Future<void> _attachRemoteStreamInternal(
    _PeerSession session,
    MediaStream stream,
  ) async {
    final peerId = session.peerId;
    if (!_canAttachRemoteStream(session)) {
      return;
    }

    try {
      final renderer = await _getOrCreateRemoteRenderer(peerId);
      if (renderer == null || !_canAttachRemoteStream(session)) {
        return;
      }

      if (kIsWeb) {
        renderer.muted = !_isSpeakerOn;
        renderer.volume = _isSpeakerOn ? 1.0 : 0.0;
        renderer.srcObject = stream;
      } else {
        renderer.srcObject = stream;
        for (final audioTrack in stream.getAudioTracks()) {
          audioTrack.enabled = true;
          try {
            await Helper.setVolume(1.0, audioTrack);
          } catch (error, stackTrace) {
            _reportNonFatalError(
              'set incoming audio track volume',
              error,
              stackTrace,
            );
          }
        }
        if (_isSpeakerOn) {
          await _maximizeAndroidSpeakerVolume();
        }
      }

      if (!_canAttachRemoteStream(session)) {
        return;
      }

      if (kIsWeb && _mediaRecorder != null) {
        _webRecordingHelper.addRemoteStream(stream);
      }

      setState(() {
        _focusedRemotePeerId ??= peerId;
        _isRemoteConnected = true;
        _errorMessage = null;
        _statusMessage = _connectedStatusMessage();
      });
    } catch (error, stackTrace) {
      if (!_isCleaningUp && !_hasEndedCall) {
        _reportNonFatalError('attach remote stream', error, stackTrace);
      }
    }
  }

  bool _canAttachRemoteStream(_PeerSession session) {
    return mounted &&
        !_hasEndedCall &&
        !_isCleaningUp &&
        !session.isClosing &&
        identical(_peerSessions[session.peerId], session);
  }

  Future<RTCVideoRenderer?> _getOrCreateRemoteRenderer(String peerId) {
    final existingRenderer = _remoteRenderers[peerId];
    if (existingRenderer != null) {
      return Future<RTCVideoRenderer?>.value(existingRenderer);
    }

    final pendingInitialization = _remoteRendererInitializations[peerId];
    if (pendingInitialization != null) {
      return pendingInitialization;
    }

    final renderer = RTCVideoRenderer();
    late final Future<RTCVideoRenderer?> initialization;
    initialization = () async {
      try {
        await renderer.initialize();

        // initialize() crosses the platform channel. The page or peer can be
        // torn down while it is in flight, so never publish a stale renderer.
        if (!mounted ||
            _hasEndedCall ||
            _isCleaningUp ||
            !_peerSessions.containsKey(peerId)) {
          await _disposeAbandonedRemoteRenderer(renderer, peerId);
          return null;
        }

        _remoteRenderers[peerId] = renderer;
        return renderer;
      } catch (_) {
        try {
          await renderer.dispose();
        } catch (error, stackTrace) {
          _reportNonFatalError(
            'dispose failed remote renderer',
            error,
            stackTrace,
          );
        }
        rethrow;
      } finally {
        if (identical(_remoteRendererInitializations[peerId], initialization)) {
          _remoteRendererInitializations.remove(peerId);
        }
      }
    }();
    _remoteRendererInitializations[peerId] = initialization;
    return initialization;
  }

  Future<void> _disposeAbandonedRemoteRenderer(
    RTCVideoRenderer renderer,
    String peerId,
  ) async {
    try {
      await renderer.dispose();
    } catch (error, stackTrace) {
      _reportNonFatalError(
        'dispose abandoned remote renderer for $peerId',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _maximizeAndroidSpeakerVolume() async {
    if (kIsWeb) {
      return;
    }

    try {
      await Helper.setSpeakerphoneOn(true);
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _audioOutputChannel.invokeMethod<void>('maximizeSpeakerVolume');
      }
    } catch (error, stackTrace) {
      _reportNonFatalError(
        'maximize Android speaker volume',
        error,
        stackTrace,
      );
    }
  }

  void _enableWebAudio({bool showMessage = true, bool markUnlocked = true}) {
    if (!kIsWeb) {
      return;
    }

    var hasRemoteAudio = false;
    for (final renderer in _remoteRenderers.values) {
      if (renderer.srcObject?.getAudioTracks().isNotEmpty ?? false) {
        hasRemoteAudio = true;
      }
      // These setters also retry HTMLAudioElement.play(). Calling them from
      // this tap satisfies browser autoplay policies that blocked sound.
      renderer.muted = false;
      renderer.volume = 1.0;
    }

    if (mounted) {
      setState(() {
        _isSpeakerOn = true;
        // Do not hide the unlock prompt before a remote audio element exists.
        // A later stream would otherwise be blocked with no recovery action.
        _webAudioUnlocked = markUnlocked && hasRemoteAudio;
      });
      if (showMessage && hasRemoteAudio) {
        _showSnackBar('Class sound enabled at full volume');
      }
    }
  }

  Future<void> _restoreIncomingAudioPlayback() async {
    if (!mounted || _hasEndedCall || _isCleaningUp || !_isSpeakerOn) {
      return;
    }

    if (kIsWeb) {
      // A lifecycle callback is not a trusted user gesture, so keep the
      // visible recovery action available if the browser still blocks play().
      _enableWebAudio(showMessage: false, markUnlocked: false);
      return;
    }

    for (final renderer in _remoteRenderers.values) {
      final stream = renderer.srcObject;
      for (final audioTrack
          in stream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
        audioTrack.enabled = true;
        try {
          await Helper.setVolume(1.0, audioTrack);
        } catch (error, stackTrace) {
          _reportNonFatalError(
            'restore incoming audio track volume',
            error,
            stackTrace,
          );
        }
      }
    }

    await _maximizeAndroidSpeakerVolume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_recoverAfterAppResume());
    }
  }

  Future<void> _recoverAfterAppResume() async {
    await _enableScreenAwake();
    await _restoreIncomingAudioPlayback();
    await _recoverAfterConnectivityReturns();
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

    final videoTrack = _localStream!.getVideoTracks().isNotEmpty
        ? _localStream!.getVideoTracks().first
        : null;
    if (_isVideoOff || videoTrack == null || !videoTrack.enabled) {
      _showSnackBar('Turn camera on before recording.');
      return;
    }
    if (videoTrack.muted == true) {
      _showSnackBar(
        'The camera is not sending video. Turn it off and on, then try again.',
      );
      return;
    }

    try {
      if (kIsWeb) {
        _localVideoPath =
            'web_recording_${DateTime.now().millisecondsSinceEpoch}';
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
      _recordingPresentationEvents.clear();
      _lastRecordedPresentationState = null;
      _recordPresentationEvent(force: true);
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
        _recordingPresentationEvents.clear();
        _lastRecordedPresentationState = null;
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

    if (!widget.isTeacher && peerId == _localParticipantId) {
      _studentReconnectTimer?.cancel();
      _studentReconnectTimer = null;
      _studentReconnectAttempts = 0;
      _studentReconnectInProgress = false;
      _showStudentReconnectAction = false;
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

    if (!widget.isTeacher && peerId == _localParticipantId) {
      _scheduleStudentReconnect();
    }
  }

  void _scheduleStudentReconnect({Duration? delay}) {
    if (widget.isTeacher || _hasEndedCall || _isCleaningUp) return;

    _studentReconnectTimer?.cancel();
    _studentReconnectTimer = Timer(delay ?? _studentReconnectDelay, () {
      if (!_isStudentTeacherConnected && !_hasEndedCall && !_isCleaningUp) {
        if (_studentReconnectAttempts >= _maxStudentReconnectAttempts) {
          _showReconnectAction();
        } else {
          unawaited(_restartStudentConnection());
        }
      }
    });
  }

  void _showReconnectAction() {
    if (!mounted) return;
    setState(() {
      _showStudentReconnectAction = true;
      _statusMessage = 'Could not reconnect automatically.';
    });
  }

  Future<void> _restartStudentConnection({bool manual = false}) async {
    if (widget.isTeacher ||
        _studentReconnectInProgress ||
        _hasEndedCall ||
        _isCleaningUp ||
        _isStudentTeacherConnected) {
      return;
    }

    if (manual) {
      _studentReconnectAttempts = 0;
    }
    if (_studentReconnectAttempts >= _maxStudentReconnectAttempts) {
      _showReconnectAction();
      return;
    }

    _studentReconnectInProgress = true;
    _studentReconnectAttempts++;
    _studentReconnectTimer?.cancel();
    _studentReconnectTimer = null;

    if (mounted) {
      setState(() {
        _showStudentReconnectAction = false;
        _statusMessage =
            'Reconnecting... attempt $_studentReconnectAttempts of $_maxStudentReconnectAttempts';
      });
    }

    try {
      await _closePeerSession(
        _localParticipantId,
        removeSignals: true,
      ).timeout(const Duration(seconds: 5));

      // Rotating this ID tells the teacher to discard its disconnected peer
      // even though the student's account/participant ID stays the same.
      _connectionId = _buildConnectionId();
      await _registerParticipant().timeout(const Duration(seconds: 5));
      await _startStudentPeer().timeout(const Duration(seconds: 5));
    } catch (error, stackTrace) {
      _reportNonFatalError('restart student connection', error, stackTrace);
    } finally {
      _studentReconnectInProgress = false;
    }

    if (!_isStudentTeacherConnected) {
      _scheduleStudentReconnect(delay: _studentConnectTimeout);
    }
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
        _webRecordedBlob = await _webRecordingHelper.stop();
        success =
            _webRecordedBlob != null &&
            _webRecordingHelper.recordedSizeBytes > 0;
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
    final presentationEvents = _recordingPresentationEvents
        .map((event) => Map<String, dynamic>.from(event))
        .toList(growable: false);

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
        'upload_progress': 0,
        'upload_updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    }

    Future<TaskSnapshot> waitForRecordingUpload(UploadTask uploadTask) async {
      FirebaseStorage.instance.setMaxUploadRetryTime(_uploadRetryLimit);
      var lastPublishedProgress = -5;
      Future<void> pendingProgressUpdate = Future<void>.value();
      final progressSubscription = uploadTask.snapshotEvents.listen((snapshot) {
        final totalBytes = snapshot.totalBytes;
        final progress = totalBytes <= 0
            ? 0
            : ((snapshot.bytesTransferred * 100) / totalBytes)
                  .clamp(0, 100)
                  .round();

        if (mounted) {
          setState(() => _statusMessage = 'Uploading video... $progress%');
        }

        if (progress >= lastPublishedProgress + 5 || progress == 100) {
          lastPublishedProgress = progress;
          pendingProgressUpdate = pendingProgressUpdate.then(
            (_) => updateRecordedClass(<String, dynamic>{
              'upload_status': 'uploading',
              'upload_progress': progress,
              'upload_updated_at': DateTime.now().millisecondsSinceEpoch,
            }),
          );
        }
      });

      try {
        return await uploadTask;
      } finally {
        await progressSubscription.cancel();
        // Finish queued progress writes before the caller writes the final
        // ready/failed state, otherwise a late "uploading" update can win.
        await pendingProgressUpdate;
      }
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
        'has_shared_content': presentationEvents.isNotEmpty,
        if (presentationEvents.isNotEmpty) ...<String, dynamic>{
          'presentation_events': presentationEvents,
          'presentation_version': 1,
        },
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
      if (_webRecordedBlob == null ||
          _webRecordingHelper.recordedSizeBytes <= 0) {
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
      final requiresCompatibilityConversion = fileExtension == 'webm';

      fileSizeBytes = _webRecordingHelper.recordedSizeBytes;
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
        'mime_type': recordedMime,
        'compatibility_status': requiresCompatibilityConversion
            ? 'waiting'
            : 'ready',
        'upload_progress': 0,
        'upload_updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      final metadata = SettableMetadata(
        contentType: recordedMime,
        customMetadata: customMetadata,
      );

      try {
        final snapshot = await waitForRecordingUpload(
          storageRef.putBlob(_webRecordedBlob, metadata),
        );
        if (snapshot.state == TaskState.success) {
          videoUrl = await storageRef.getDownloadURL().timeout(
            const Duration(seconds: 30),
          );
          uploadStatus = 'ready';
          debugPrint('Video uploaded to Storage: $videoUrl');
          _webRecordedBlob = null;
          await updateRecordedClass(<String, dynamic>{
            'video_url': videoUrl,
            'upload_status': uploadStatus,
            'storage_path': storagePath,
            'mime_type': recordedMime,
            'upload_progress': 100,
            'upload_updated_at': DateTime.now().millisecondsSinceEpoch,
            'upload_error': null,
          });
          return true;
        } else {
          await markRecordingFailed(
            'upload_failed',
            'Storage upload task failed.',
          );
          return false;
        }
      } on FirebaseException catch (e) {
        await markRecordingFailed(
          'upload_failed',
          _formatFirebaseStorageError(e),
        );
        return false;
      } catch (e) {
        await markRecordingFailed('upload_failed', 'Video upload failed: $e');
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
              'upload_progress': 0,
              'upload_updated_at': DateTime.now().millisecondsSinceEpoch,
            });

            final metadata = SettableMetadata(
              contentType: 'video/mp4',
              customMetadata: customMetadata,
            );

            final snapshot = await waitForRecordingUpload(
              storageRef.putFile(file, metadata),
            );
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
                'upload_progress': 100,
                'upload_updated_at': DateTime.now().millisecondsSinceEpoch,
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
        await _sessionSignalRef(peerId).remove();
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
      _studentReconnectTimer?.cancel();
      _studentReconnectTimer = null;
      _participantHeartbeatTimer?.cancel();
      _participantHeartbeatTimer = null;
      _classEndConfirmationTimer?.cancel();
      _classEndConfirmationTimer = null;
      // 1. Cancel all Firebase listeners first
      await _participantsSub?.cancel();
      _participantsSub = null;
      await _classStatusSub?.cancel();
      _classStatusSub = null;
      await _firebaseConnectionSub?.cancel();
      _firebaseConnectionSub = null;

      // 2. Remove room state from database
      if (shouldMutateRoom) {
        if (removeLiveClass) {
          await _liveClassRef.remove();
        } else {
          await _removeParticipantRegistrationIfCurrent();
          if (!widget.isTeacher) {
            await _removeStudentSignalsIfCurrent();
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

  bool get _isStudentTeacherConnected {
    if (widget.isTeacher) return true;
    return _remoteRenderers[_localParticipantId]?.srcObject != null;
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
      if (nextVal) {
        _enableWebAudio();
      } else {
        for (final renderer in _remoteRenderers.values) {
          renderer.muted = true;
          renderer.volume = 0.0;
        }
        setState(() {
          _isSpeakerOn = false;
          _webAudioUnlocked = false;
        });
        _showSnackBar('Class sound muted');
      }
    } else {
      try {
        if (nextVal) {
          await _maximizeAndroidSpeakerVolume();
        } else {
          await Helper.setSpeakerphoneOn(false);
        }
        setState(() {
          _isSpeakerOn = nextVal;
        });
        _showSnackBar(
          nextVal ? 'Speakerphone turned on' : 'Earpiece turned on',
        );
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

  Future<void> _requestCallExit() async {
    if (!mounted ||
        _hasEndedCall ||
        _isCleaningUp ||
        _isSharedDocumentPickerOpen ||
        _isExitConfirmationOpen) {
      return;
    }

    final ignoreBackUntil = _ignoreBackNavigationUntil;
    if (ignoreBackUntil != null && DateTime.now().isBefore(ignoreBackUntil)) {
      return;
    }

    _isExitConfirmationOpen = true;
    try {
      final shouldExit = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(widget.isTeacher ? 'End live class?' : 'Leave class?'),
          content: Text(
            widget.isTeacher
                ? 'This will end the live class for every student.'
                : 'You will leave the live class. The teacher and other students will remain connected.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              child: Text(widget.isTeacher ? 'End Class' : 'Leave'),
            ),
          ],
        ),
      );

      if (shouldExit == true && mounted) {
        await _endCall();
      }
    } finally {
      _isExitConfirmationOpen = false;
    }
  }

  int? _parseInt(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _studentReconnectTimer?.cancel();
    _studentReconnectTimer = null;
    _participantHeartbeatTimer?.cancel();
    _participantHeartbeatTimer = null;
    _classEndConfirmationTimer?.cancel();
    _classEndConfirmationTimer = null;
    unawaited(_disableScreenAwake());
    _firebaseConnectionSub?.cancel();
    _drawingStrokesSub?.cancel();
    _currentStrokeSub?.cancel();
    _sharedDocumentSub?.cancel();
    _documentTransformationController.dispose();
    if (!_hasEndedCall) {
      unawaited(_cleanupRoomState(removeLiveClass: widget.isTeacher));
      // Cleanup can wait on a lost network. The connection-specific database
      // guards above keep a new page safe, so release the local route lock now.
      _releaseSession();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hideLiveChrome = _isStudentDocumentFullScreen;
    final controlSurfaceColor = _sharedDocUrl != null
        ? Colors.black.withValues(alpha: 0.78)
        : Colors.white.withValues(alpha: 0.2);
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_requestCallExit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTapDown: (_) {
                    if (kIsWeb &&
                        _isRemoteConnected &&
                        _isSpeakerOn &&
                        !_webAudioUnlocked) {
                      _enableWebAudio(showMessage: false);
                    }
                  },
                  onTap: widget.isTeacher
                      ? () => setState(
                          () => _showOwnCameraSmall = !_showOwnCameraSmall,
                        )
                      : null,
                  child: Container(
                    color: const Color(0xFF1C1C1E),
                    child: _buildMainVideoPanel(),
                  ),
                ),
              ),
              if (!hideLiveChrome)
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
              if (!hideLiveChrome && _buildPipContent() != null)
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
                    onTap: widget.isTeacher
                        ? () => setState(
                            () => _showOwnCameraSmall = !_showOwnCameraSmall,
                          )
                        : null,
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
              if (!hideLiveChrome)
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
              if (kIsWeb && _isRemoteConnected && !_webAudioUnlocked)
                Positioned(
                  top: 132,
                  left: 20,
                  right: 20,
                  child: Center(
                    child: FilledButton.icon(
                      onPressed: _enableWebAudio,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1F7A4D),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                      ),
                      icon: const Icon(Icons.volume_up_rounded),
                      label: Text(
                        'Tap to enable class sound',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              if (!hideLiveChrome)
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
                              : controlSurfaceColor,
                          iconColor: _isRecording
                              ? Colors.white
                              : Colors.redAccent,
                          enabled: _canStartRecording,
                          dimWhenDisabled: !_isRecording,
                          onTap: _startRecording,
                        ),
                      _buildControlButton(
                        tooltip: kIsWeb
                            ? (_isSpeakerOn
                                  ? 'Mute class sound'
                                  : 'Enable class sound')
                            : (_isSpeakerOn
                                  ? 'Switch to earpiece'
                                  : 'Switch to speaker'),
                        icon: _isSpeakerOn
                            ? Icons.volume_up_rounded
                            : Icons.volume_down_rounded,
                        color: _isSpeakerOn
                            ? controlSurfaceColor
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
                            : controlSurfaceColor,
                        iconColor: Colors.white,
                        onTap: _toggleMic,
                      ),
                      _buildControlButton(
                        tooltip: 'End call',
                        icon: Icons.call_end_rounded,
                        color: Colors.redAccent,
                        iconColor: Colors.white,
                        size: 64,
                        onTap: _requestCallExit,
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
                            : controlSurfaceColor,
                        iconColor: Colors.white,
                        onTap: _toggleVideo,
                      ),
                      if (widget.isTeacher && _sharedDocUrl == null)
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
                      if (widget.isTeacher && _sharedDocUrl == null)
                        _buildControlButton(
                          tooltip: 'Share Document',
                          icon: Icons.present_to_all_rounded,
                          color: controlSurfaceColor,
                          iconColor: Colors.white,
                          enabled: !_isProcessing,
                          onTap: () async {
                            await _shareDocumentPicker();
                          },
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
    if (_hasEndedCall && _errorMessage != null) {
      return _buildRemotePlaceholder();
    }

    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (!_renderersInitialized) {
      return _buildRemotePlaceholder();
    }

    if (_sharedDocUrl != null) {
      return _buildSharedWhiteboardPanel();
    }

    // A student must always see the teacher in the full main area. Other
    // students never push the teacher into a grid or the small self-view.
    if (!widget.isTeacher) {
      final teacherRenderer = _remoteRenderers[_localParticipantId];
      if (teacherRenderer?.srcObject != null) {
        return ColoredBox(
          color: Colors.black,
          child: RTCVideoView(
            teacherRenderer!,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
        );
      }
      return _buildRemotePlaceholder();
    }

    final showLocalInMain = !_showOwnCameraSmall;
    if (showLocalInMain) {
      return _buildLocalVideoView(expanded: true);
    }

    if (_isRemoteConnected) {
      return _buildRemoteVideoArea();
    }

    return _buildRemotePlaceholder();
  }

  void _listenForSharedWhiteboard() {
    _sharedDocumentSub = _webrtcRef.child('shared_document').onValue.listen((
      event,
    ) {
      if (!mounted) return;
      final val = event.snapshot.value;
      if (val is Map) {
        final doc = Map<String, dynamic>.from(val);
        final newUrl = doc['url']?.toString();
        final newName = doc['file_name']?.toString();
        final newType = doc['file_type']?.toString();
        final rawPage = _parseInt(doc['current_page']) ?? 1;
        final newPageCount = _parseInt(doc['page_count']) ?? 0;
        final maxPage = newPageCount > 0 ? newPageCount : rawPage;
        final newPage = rawPage.clamp(1, maxPage).toInt();

        if (newUrl != _sharedDocUrl) {
          _documentTransformationController.value = Matrix4.identity();
          setState(() {
            _sharedDocUrl = newUrl;
            _sharedDocName = newName;
            _sharedDocType = newType;
            _sharedDocPage = newPage;
            _sharedDocPageCount = newPageCount;
            _documentZoom = 1.0;
            _isDocumentFullScreen = !widget.isTeacher && newUrl != null;
            _pdfReloadNonce = 0;
            _sharedPdfDocumentRef = null;
            _showWhiteboardToolbar = true;
          });
          if (newUrl != null && newType == 'pdf' && !shouldUseWebPdfRenderer) {
            unawaited(_prepareSharedPdfDocument(newUrl));
          }
        } else {
          final pageChanged = newPage != _sharedDocPage;
          if (pageChanged) {
            _documentTransformationController.value = Matrix4.identity();
          }
          setState(() {
            _sharedDocName = newName;
            _sharedDocPage = newPage;
            if (newPageCount > 0) {
              _sharedDocPageCount = newPageCount;
            }
            if (pageChanged) {
              _documentZoom = 1.0;
            }
          });
        }
        _recordPresentationEvent();
      } else {
        final wasSharing = _sharedDocUrl != null;
        setState(() {
          _sharedDocUrl = null;
          _sharedDocName = null;
          _sharedDocType = null;
          _sharedDocPage = 1;
          _sharedDocPageCount = 0;
          _sharedPdfDocumentRef = null;
          _documentZoom = 1.0;
          _isDocumentFullScreen = false;
          _localSharedFile = null;
        });
        _documentTransformationController.value = Matrix4.identity();
        if (wasSharing) {
          _recordPresentationEvent(hidden: true);
        }
      }
    });

    _drawingStrokesSub = _webrtcRef.child('drawing_strokes').onValue.listen((
      event,
    ) {
      if (!mounted) return;
      final val = event.snapshot.value;
      final List<DrawingStroke> strokes = [];
      if (val is Map) {
        for (final entry in val.entries) {
          if (entry.value is Map) {
            strokes.add(DrawingStroke.fromJson(entry.value as Map));
          }
        }
      }
      setState(() {
        _completedStrokes = strokes;
      });
    });

    _currentStrokeSub = _webrtcRef.child('current_stroke').onValue.listen((
      event,
    ) {
      if (!mounted) return;
      final val = event.snapshot.value;
      if (val is Map) {
        setState(() {
          _currentStroke = DrawingStroke.fromJson(val);
        });
      } else {
        setState(() {
          _currentStroke = null;
        });
      }
    });
  }

  void _recordPresentationEvent({bool hidden = false, bool force = false}) {
    final recordingStart = _recordingStartTime;
    if (!widget.isTeacher ||
        recordingStart == null ||
        (!force && !_isRecording)) {
      return;
    }

    final hasDocument = !hidden && _sharedDocUrl != null;
    if (!hasDocument && !hidden) {
      return;
    }

    final action = hidden ? 'hide' : 'show';
    final stateKey = hasDocument
        ? '$action|$_sharedDocUrl|$_sharedDocType|$_sharedDocPage'
        : action;
    if (_lastRecordedPresentationState == stateKey) {
      return;
    }

    final event = <String, dynamic>{
      'offset_ms': max(
        0,
        DateTime.now().difference(recordingStart).inMilliseconds,
      ),
      'action': action,
    };
    if (hasDocument) {
      event.addAll(<String, dynamic>{
        'url': _sharedDocUrl,
        'file_name': _sharedDocName ?? 'Shared note',
        'file_type': _sharedDocType ?? 'image',
        'page': _sharedDocPage,
      });
    }

    _recordingPresentationEvents.add(event);
    _lastRecordedPresentationState = stateKey;
  }

  PdfDocumentRef _createSharedPdfDocumentRef(String url) {
    return PdfDocumentRefUri(
      Uri.parse(url),
      key: PdfDocumentRefKey('$url#live-pdf-$_pdfReloadNonce'),
      timeout: const Duration(minutes: 2),
      // Full-file loading is more reliable than HTTP range/progressive reads
      // for tokenized Firebase URLs on iPhone Safari.
      useProgressiveLoading: false,
    );
  }

  PdfDocumentRef _createSharedPdfDataRef(Uint8List bytes, String url) {
    return PdfDocumentRefData(
      bytes,
      sourceName: _sharedDocName ?? url,
      key: PdfDocumentRefKey('$url#live-pdf-data-$_pdfReloadNonce'),
      useProgressiveLoading: false,
    );
  }

  Future<void> _prepareSharedPdfDocument(String url) async {
    final reloadNonce = _pdfReloadNonce;
    Uint8List? bytes;

    // The teacher already selected the PDF. Reusing those bytes avoids a
    // second cross-origin download, which intermittently fails on iOS Safari.
    final localFile = _localSharedFile;
    if (widget.isTeacher &&
        localFile != null &&
        localFile.name == _sharedDocName) {
      bytes = localFile.bytes;
      final localPath = localFile.path;
      if (bytes == null && !kIsWeb && localPath != null) {
        try {
          bytes = await File(localPath).readAsBytes();
        } catch (error, stackTrace) {
          _reportNonFatalError('read selected PDF bytes', error, stackTrace);
        }
      }
    }

    if (bytes == null) {
      try {
        bytes = await FirebaseStorage.instance
            .refFromURL(url)
            .getData(_maxSharedPdfBytes);
      } catch (error, stackTrace) {
        _reportNonFatalError('download shared PDF bytes', error, stackTrace);
      }
    }

    if (!mounted || _sharedDocUrl != url || _pdfReloadNonce != reloadNonce) {
      return;
    }

    setState(() {
      _sharedPdfDocumentRef = bytes != null
          ? _createSharedPdfDataRef(bytes, url)
          : _createSharedPdfDocumentRef(url);
    });
  }

  void _retrySharedPdf() {
    final url = _sharedDocUrl;
    if (url == null || !mounted) {
      return;
    }

    final useWebRenderer = shouldUseWebPdfRenderer;
    if (useWebRenderer) {
      disposeWebPdfDocument(url);
    }

    setState(() {
      _pdfReloadNonce++;
      _sharedPdfDocumentRef = null;
    });
    if (!useWebRenderer) {
      unawaited(_prepareSharedPdfDocument(url));
    }
  }

  void _resetDocumentZoom() {
    _documentTransformationController.value = Matrix4.identity();
    if (mounted && _documentZoom != 1.0) {
      setState(() => _documentZoom = 1.0);
    } else {
      _documentZoom = 1.0;
    }
  }

  void _setDocumentZoom(double zoom) {
    final nextZoom = zoom.clamp(1.0, 5.0).toDouble();
    _documentTransformationController.value = Matrix4.diagonal3Values(
      nextZoom,
      nextZoom,
      1.0,
    );
    if (mounted) {
      setState(() => _documentZoom = nextZoom);
    }
  }

  void _toggleDocumentFullScreen() {
    if (widget.isTeacher || !mounted) {
      return;
    }
    setState(() {
      _isDocumentFullScreen = !_isDocumentFullScreen;
    });
  }

  void _changeSharedPdfPage(int requestedPage) {
    if (!widget.isTeacher || _sharedDocType != 'pdf') {
      return;
    }

    final pageCount = _sharedDocPageCount;
    if (pageCount <= 0) {
      _showSnackBar('PDF pages are still loading.');
      return;
    }

    final nextPage = requestedPage.clamp(1, pageCount).toInt();
    if (nextPage == _sharedDocPage) {
      return;
    }

    _documentTransformationController.value = Matrix4.identity();
    setState(() {
      _sharedDocPage = nextPage;
      _documentZoom = 1.0;
    });

    _pdfPageSyncTask = _pdfPageSyncTask.then(
      (_) => _webrtcRef.child('shared_document').update(<String, dynamic>{
        'current_page': nextPage,
        'page_count': pageCount,
      }),
    );
  }

  void _handleSharedPdfLoaded(PdfDocument document) {
    _handleSharedPdfPageCount(document.pages.length);
  }

  void _handleSharedPdfPageCount(int pageCount) {
    if (pageCount <= 0 || pageCount == _sharedDocPageCount) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sharedDocType != 'pdf') {
        return;
      }

      final boundedPage = _sharedDocPage.clamp(1, pageCount).toInt();
      setState(() {
        _sharedDocPageCount = pageCount;
        _sharedDocPage = boundedPage;
      });

      if (widget.isTeacher) {
        unawaited(
          _webrtcRef.child('shared_document').update(<String, dynamic>{
            'current_page': boundedPage,
            'page_count': pageCount,
          }),
        );
      }
    });
  }

  void _onDrawingStart(Offset point) {
    _activePoints = [point];
    _currentStroke = DrawingStroke(
      points: _activePoints,
      color: _selectedDrawColor,
      strokeWidth: _selectedDrawWidth,
    );
    setState(() {});
    unawaited(_webrtcRef.child('current_stroke').set(_currentStroke!.toJson()));
  }

  void _onDrawingUpdate(Offset point) {
    _activePoints.add(point);
    _currentStroke = DrawingStroke(
      points: _activePoints,
      color: _selectedDrawColor,
      strokeWidth: _selectedDrawWidth,
    );
    setState(() {});

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSyncTime > 100) {
      _lastSyncTime = now;
      unawaited(
        _webrtcRef.child('current_stroke').set(_currentStroke!.toJson()),
      );
    }
  }

  void _onDrawingEnd() {
    if (_currentStroke != null && _currentStroke!.points.isNotEmpty) {
      final finishedStroke = _currentStroke!;
      _completedStrokes.add(finishedStroke);
      _currentStroke = null;
      _activePoints = [];
      setState(() {});

      unawaited(
        _webrtcRef.child('drawing_strokes').push().set(finishedStroke.toJson()),
      );
      unawaited(_webrtcRef.child('current_stroke').remove());
    }
  }

  Future<void> _clearDrawings() async {
    setState(() {
      _completedStrokes.clear();
      _currentStroke = null;
    });
    await _webrtcRef.child('drawing_strokes').remove();
    await _webrtcRef.child('current_stroke').remove();
  }

  Future<void> _shareDocumentPicker() async {
    if (_isSharedDocumentPickerOpen || _isProcessing) {
      return;
    }

    FilePickerResult? result;
    _isSharedDocumentPickerOpen = true;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
      );
    } catch (e) {
      if (mounted && !_hasEndedCall) {
        _showSnackBar('Unable to open document picker: $e');
      }
      return;
    } finally {
      _isSharedDocumentPickerOpen = false;
      // Some Android system pickers forward their cancel/back event to the
      // resumed Flutter route. Do not treat that same event as "End call".
      _ignoreBackNavigationUntil = DateTime.now().add(
        const Duration(milliseconds: 500),
      );
    }

    if (!mounted || _hasEndedCall || result == null || result.files.isEmpty) {
      return;
    }

    try {
      final file = result.files.first;
      final fileExtension = file.extension?.toLowerCase() ?? '';
      final isPdf = fileExtension == 'pdf';
      final fileType = isPdf ? 'pdf' : 'image';

      setState(() {
        _localSharedFile = file;
        _isProcessing = true;
        _statusMessage = 'Uploading shared document...';
      });

      final authUid = await FirebaseUploadAuthService.ensureSignedIn();
      if (authUid == null) {
        throw Exception('Firebase authentication failed.');
      }

      final subjectKey = widget.subjectId ?? 'live_call_docs';
      final docKey = 'shared_doc_${DateTime.now().millisecondsSinceEpoch}';
      final ref = FirebaseStorage.instance
          .ref()
          .child('notes')
          .child(widget.classId)
          .child(subjectKey)
          .child('$docKey.$fileExtension');

      if (kIsWeb) {
        final bytes = file.bytes;
        if (bytes == null) {
          throw Exception('Could not read file bytes.');
        }
        final mimeType = isPdf
            ? 'application/pdf'
            : (fileExtension == 'png' ? 'image/png' : 'image/jpeg');
        await ref.putData(bytes, SettableMetadata(contentType: mimeType));
      } else {
        final localFile = File(file.path!);
        await ref.putFile(localFile);
      }

      final downloadUrl = await ref.getDownloadURL();

      await _webrtcRef.child('drawing_strokes').remove();
      await _webrtcRef.child('current_stroke').remove();

      await _webrtcRef.child('shared_document').set({
        'url': downloadUrl,
        'file_name': file.name,
        'file_type': fileType,
        'current_page': 1,
        'page_count': 0,
      });

      setState(() {
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      _showSnackBar('Error sharing document: $e');
    }
  }

  Future<void> _stopSharingDocument() async {
    setState(() {
      _isProcessing = true;
      _localSharedFile = null;
    });
    try {
      await _clearDrawings();
      await _webrtcRef.child('shared_document').remove();
      _recordPresentationEvent(hidden: true);
    } catch (e) {
      debugPrint('Error stopping share: $e');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Widget _buildSharedWhiteboardPanel() {
    final isImage = _sharedDocType == 'image';
    final isPdf = _sharedDocType == 'pdf';

    return Column(
      children: [
        if (!_isStudentDocumentFullScreen) _buildParticipantVideoStrip(),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: const Color(0xFF1C1C1E),
                  child: Stack(
                    key: _canvasKey,
                    children: [
                      Positioned.fill(
                        child: Container(
                          color: Colors.white,
                          child: isImage
                              ? _buildSharedImageView()
                              : (isPdf
                                    ? _buildPdfView()
                                    : const SizedBox.shrink()),
                        ),
                      ),
                      Positioned.fill(
                        child: widget.isTeacher && _isDrawingMode
                            ? GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanStart: (details) {
                                  final box =
                                      _canvasKey.currentContext
                                              ?.findRenderObject()
                                          as RenderBox?;
                                  if (box == null) return;
                                  final localPos = box.globalToLocal(
                                    details.globalPosition,
                                  );
                                  final normX = (localPos.dx / box.size.width)
                                      .clamp(0.0, 1.0);
                                  final normY = (localPos.dy / box.size.height)
                                      .clamp(0.0, 1.0);
                                  _onDrawingStart(Offset(normX, normY));
                                },
                                onPanUpdate: (details) {
                                  final box =
                                      _canvasKey.currentContext
                                              ?.findRenderObject()
                                          as RenderBox?;
                                  if (box == null) return;
                                  final localPos = box.globalToLocal(
                                    details.globalPosition,
                                  );
                                  final normX = (localPos.dx / box.size.width)
                                      .clamp(0.0, 1.0);
                                  final normY = (localPos.dy / box.size.height)
                                      .clamp(0.0, 1.0);
                                  _onDrawingUpdate(Offset(normX, normY));
                                },
                                onPanEnd: (details) {
                                  _onDrawingEnd();
                                },
                                child: CustomPaint(
                                  painter: DrawingPainter(
                                    completedStrokes: _completedStrokes,
                                    currentStroke: _currentStroke,
                                  ),
                                  size: Size.infinite,
                                ),
                              )
                            : IgnorePointer(
                                child: CustomPaint(
                                  painter: DrawingPainter(
                                    completedStrokes: _completedStrokes,
                                    currentStroke: _currentStroke,
                                  ),
                                  size: Size.infinite,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              _buildDocumentViewControls(),
              _buildWhiteboardToolbar(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSharedImageView() {
    final localFile = _localSharedFile;
    Widget? image;
    if (widget.isTeacher && localFile != null) {
      if (kIsWeb) {
        final bytes = localFile.bytes;
        if (bytes != null) {
          image = Image.memory(bytes, fit: BoxFit.contain);
        }
      } else {
        final path = localFile.path;
        if (path != null) {
          image = Image.file(File(path), fit: BoxFit.contain);
        }
      }
    }

    image ??= UniversalImage(
      key: ValueKey<String>('shared-image-${_sharedDocUrl!}'),
      imageUrl: _sharedDocUrl!,
      fit: BoxFit.contain,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }
        return const Center(
          child: CircularProgressIndicator(color: AppColors.primaryNavy),
        );
      },
      errorBuilder: (context, error, stackTrace) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_rounded,
                color: Colors.grey,
                size: 48,
              ),
              const SizedBox(height: 12),
              const Text(
                'Shared image could not be displayed',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => unawaited(
                  launchUrl(
                    Uri.parse(_sharedDocUrl!),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open externally'),
              ),
            ],
          ),
        ),
      ),
    );
    return _buildZoomableSharedDocument(image);
  }

  Widget _buildPdfView() {
    if (shouldUseWebPdfRenderer) {
      final localPdfBytes =
          widget.isTeacher && _localSharedFile?.name == _sharedDocName
          ? _localSharedFile?.bytes
          : null;
      return _buildZoomableSharedDocument(
        WebPdfPageView(
          key: ValueKey<String>('web-pdf-${_sharedDocUrl!}'),
          url: _sharedDocUrl!,
          data: localPdfBytes,
          pageNumber: _sharedDocPage,
          reloadNonce: _pdfReloadNonce,
          onDocumentLoaded: _handleSharedPdfPageCount,
          onRetry: _retrySharedPdf,
        ),
      );
    }

    final documentRef = _sharedPdfDocumentRef;
    if (documentRef == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return PdfDocumentViewBuilder(
      key: ValueKey<String>('live-pdf-${_sharedDocUrl!}-$_pdfReloadNonce'),
      documentRef: documentRef,
      loadingBuilder: (context) => const Center(
        child: CircularProgressIndicator(color: AppColors.primaryNavy),
      ),
      errorBuilder: (context, error, stackTrace) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.picture_as_pdf_rounded,
                  size: 56,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 12),
                const Text(
                  'PDF could not be displayed',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _retrySharedPdf,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry PDF'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(
                        launchUrl(
                          Uri.parse(_sharedDocUrl!),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open externally'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
      builder: (context, document) {
        if (document == null || document.pages.isEmpty) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primaryNavy),
          );
        }

        _handleSharedPdfLoaded(document);
        final page = _sharedDocPage.clamp(1, document.pages.length).toInt();
        return _buildZoomableSharedDocument(
          PdfPageView(
            key: ValueKey<String>('${_sharedDocUrl!}-$page'),
            document: document,
            pageNumber: page,
            maximumDpi: kIsWeb ? 180 : 240,
            backgroundColor: Colors.white,
            decoration: const BoxDecoration(color: Colors.white),
          ),
        );
      },
    );
  }

  Widget _buildZoomableSharedDocument(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return InteractiveViewer(
          transformationController: _documentTransformationController,
          minScale: 1.0,
          maxScale: 5.0,
          panEnabled: !_isDrawingMode,
          scaleEnabled: !_isDrawingMode,
          clipBehavior: Clip.hardEdge,
          onInteractionEnd: (details) {
            final zoom = _documentTransformationController.value
                .getMaxScaleOnAxis()
                .clamp(1.0, 5.0)
                .toDouble();
            if (mounted && (zoom - _documentZoom).abs() > 0.01) {
              setState(() => _documentZoom = zoom);
            }
          },
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildDocumentViewControls() {
    return Positioned(
      top: 12,
      right: 12,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_sharedDocType == 'pdf') ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    _sharedDocPageCount > 0
                        ? '$_sharedDocPage/$_sharedDocPageCount'
                        : 'Page $_sharedDocPage',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(width: 1, height: 24, color: Colors.white24),
              ],
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Zoom out',
                onPressed: _documentZoom > 1.0
                    ? () => _setDocumentZoom(_documentZoom - 0.5)
                    : null,
                icon: const Icon(Icons.zoom_out_rounded, color: Colors.white),
              ),
              TextButton(
                onPressed: _resetDocumentZoom,
                child: Text(
                  '${(_documentZoom * 100).round()}%',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Zoom in',
                onPressed: _documentZoom < 5.0
                    ? () => _setDocumentZoom(_documentZoom + 0.5)
                    : null,
                icon: const Icon(Icons.zoom_in_rounded, color: Colors.white),
              ),
              if (!widget.isTeacher) ...[
                Container(width: 1, height: 24, color: Colors.white24),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _isStudentDocumentFullScreen
                      ? 'Exit full screen'
                      : 'View full screen',
                  onPressed: _toggleDocumentFullScreen,
                  icon: Icon(
                    _isStudentDocumentFullScreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWhiteboardToolbar() {
    if (_isStudentDocumentFullScreen) {
      return const SizedBox.shrink();
    }

    if (!_showWhiteboardToolbar) {
      return Positioned(
        bottom: 120,
        right: 20,
        child: Tooltip(
          message: 'Show tools',
          child: GestureDetector(
            onTap: () => setState(() => _showWhiteboardToolbar = true),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 8),
                ],
              ),
              child: Icon(
                widget.isTeacher
                    ? Icons.palette_rounded
                    : Icons.visibility_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      bottom: 120,
      left: 20,
      right: 20,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isTeacher && _isDrawingMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 10),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      _buildColorButton(Colors.red),
                      const SizedBox(width: 8),
                      _buildColorButton(Colors.blue),
                      const SizedBox(width: 8),
                      _buildColorButton(Colors.green),
                      const SizedBox(width: 8),
                      _buildColorButton(Colors.yellow),
                      const SizedBox(width: 8),
                      _buildColorButton(Colors.black),
                    ],
                  ),
                  Row(
                    children: [
                      const Icon(Icons.brush, color: Colors.white70, size: 14),
                      const SizedBox(width: 8),
                      DropdownButton<double>(
                        dropdownColor: Colors.black87,
                        value: _selectedDrawWidth,
                        underline: const SizedBox.shrink(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        items: [2.0, 4.0, 6.0, 8.0, 10.0].map((width) {
                          return DropdownMenuItem<double>(
                            value: width,
                            child: Text('${width.toInt()}px'),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _selectedDrawWidth = val;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(30),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 10),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (widget.isTeacher)
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _isDrawingMode
                              ? Icons.edit_off_rounded
                              : Icons.edit_rounded,
                          color: _isDrawingMode
                              ? Colors.redAccent
                              : Colors.white,
                        ),
                        tooltip: 'Pencil Mode',
                        onPressed: () {
                          setState(() {
                            _isDrawingMode = !_isDrawingMode;
                          });
                        },
                      ),
                      if (_isDrawingMode)
                        IconButton(
                          icon: const Icon(
                            Icons.delete_sweep_rounded,
                            color: Colors.white,
                          ),
                          tooltip: 'Clear drawings',
                          onPressed: _clearDrawings,
                        ),
                      IconButton(
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white70,
                        ),
                        tooltip: 'Hide tools',
                        onPressed: () =>
                            setState(() => _showWhiteboardToolbar = false),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Icon(
                        _isDrawingMode
                            ? Icons.edit_rounded
                            : Icons.visibility_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isDrawingMode
                            ? 'Teacher drawing...'
                            : 'Viewing Presentation',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white70,
                          size: 18,
                        ),
                        tooltip: 'Hide toolbar',
                        onPressed: () =>
                            setState(() => _showWhiteboardToolbar = false),
                      ),
                    ],
                  ),
                if (_sharedDocType == 'pdf')
                  Row(
                    children: [
                      if (widget.isTeacher)
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_ios_rounded,
                            color: Colors.white,
                          ),
                          onPressed: _sharedDocPage > 1
                              ? () => _changeSharedPdfPage(_sharedDocPage - 1)
                              : null,
                        ),
                      Text(
                        _sharedDocPageCount > 0
                            ? 'Page $_sharedDocPage/$_sharedDocPageCount'
                            : 'Page $_sharedDocPage',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      if (widget.isTeacher)
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_forward_ios_rounded,
                            color: Colors.white,
                          ),
                          onPressed:
                              _sharedDocPageCount > 0 &&
                                  _sharedDocPage < _sharedDocPageCount
                              ? () => _changeSharedPdfPage(_sharedDocPage + 1)
                              : null,
                        ),
                    ],
                  )
                else
                  const SizedBox.shrink(),
                if (widget.isTeacher)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_hasPendingRecording) ...[
                        TextButton.icon(
                          onPressed: _canSaveRecording
                              ? _saveRecordingNow
                              : null,
                          icon: Icon(
                            _isSavingRecording
                                ? Icons.hourglass_empty_rounded
                                : Icons.save_rounded,
                            color: _canSaveRecording
                                ? Colors.greenAccent
                                : Colors.white38,
                            size: 18,
                          ),
                          label: Text(
                            _isSavingRecording ? 'Saving...' : 'Save Rec',
                            style: TextStyle(
                              color: _canSaveRecording
                                  ? Colors.greenAccent
                                  : Colors.white38,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      TextButton.icon(
                        onPressed: _stopSharingDocument,
                        icon: const Icon(
                          Icons.stop_rounded,
                          color: Colors.redAccent,
                          size: 18,
                        ),
                        label: const Text(
                          'Stop',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorButton(Color color) {
    final isSelected = _selectedDrawColor == color;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedDrawColor = color;
        });
      },
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.transparent,
            width: 2,
          ),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)],
        ),
      ),
    );
  }

  Widget _buildParticipantVideoStrip() {
    final List<Widget> items = [];

    if (_localRenderer.srcObject != null) {
      items.add(
        _buildVideoStripItem('You', _localRenderer, mirror: _isFrontCamera),
      );
    }

    for (final entry in _connectedRemoteRenderers) {
      items.add(
        _buildVideoStripItem(_remoteParticipantName(entry.key), entry.value),
      );
    }

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 100,
      color: Colors.black87,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) => items[index],
      ),
    );
  }

  Widget _buildVideoStripItem(
    String name,
    RTCVideoRenderer renderer, {
    bool mirror = false,
  }) {
    return Container(
      width: 140,
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RTCVideoView(renderer, mirror: mirror),
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _buildPipContent() {
    if (_isInitializing || !_renderersInitialized || _sharedDocUrl != null) {
      return null;
    }

    final showLocalInPip = !widget.isTeacher || _showOwnCameraSmall;

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

    if (connectedRenderers.length == 1) {
      final focusedEntry = _focusedRemoteEntry ?? connectedRenderers.first;
      return RTCVideoView(
        focusedEntry.value,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
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
                      child: RTCVideoView(
                        entry.value,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
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

    return RTCVideoView(
      focusedEntry.value,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
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
    if (!widget.isTeacher && peerId == _localParticipantId) {
      final teacher = _participants.firstWhere(
        (p) => p['role'] == 'teacher',
        orElse: () => <String, dynamic>{},
      );
      final name = teacher['name']?.toString();
      if (name != null && name.isNotEmpty) {
        return name;
      }
      return 'Teacher';
    }

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
    if (_hasEndedCall ||
        !_renderersInitialized ||
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
          if (!widget.isTeacher && _showStudentReconnectAction) ...[
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: () =>
                  unawaited(_restartStudentConnection(manual: true)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentRed,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
              ),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                'Try Again',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              ),
            ),
          ],
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
  _PeerSession({required this.peerId, this.remoteConnectionId});

  final String peerId;
  final String? remoteConnectionId;
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

class DrawingStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  DrawingStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
  });

  Map<String, dynamic> toJson() {
    return {
      'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      'color': color.value,
      'stroke_width': strokeWidth,
    };
  }

  factory DrawingStroke.fromJson(Map<dynamic, dynamic> json) {
    final ptsList = json['points'] as List? ?? [];
    final points = ptsList.map((p) {
      final map = p as Map;
      return Offset((map['x'] as num).toDouble(), (map['y'] as num).toDouble());
    }).toList();
    return DrawingStroke(
      points: points,
      color: Color(json['color'] as int? ?? Colors.red.value),
      strokeWidth: (json['stroke_width'] as num? ?? 3.0).toDouble(),
    );
  }
}

class DrawingPainter extends CustomPainter {
  final List<DrawingStroke> completedStrokes;
  final DrawingStroke? currentStroke;

  DrawingPainter({required this.completedStrokes, this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in completedStrokes) {
      if (stroke.points.isEmpty) continue;
      paint.color = stroke.color;
      paint.strokeWidth = stroke.strokeWidth;

      final path = Path();
      path.moveTo(
        stroke.points.first.dx * size.width,
        stroke.points.first.dy * size.height,
      );
      for (int i = 1; i < stroke.points.length; i++) {
        path.lineTo(
          stroke.points[i].dx * size.width,
          stroke.points[i].dy * size.height,
        );
      }
      canvas.drawPath(path, paint);
    }

    final current = currentStroke;
    if (current != null && current.points.isNotEmpty) {
      paint.color = current.color;
      paint.strokeWidth = current.strokeWidth;

      final path = Path();
      path.moveTo(
        current.points.first.dx * size.width,
        current.points.first.dy * size.height,
      );
      for (int i = 1; i < current.points.length; i++) {
        path.lineTo(
          current.points[i].dx * size.width,
          current.points[i].dy * size.height,
        );
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) {
    return true;
  }
}
