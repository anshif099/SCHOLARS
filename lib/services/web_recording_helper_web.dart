import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;
import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:dart_webrtc/src/media_stream_impl.dart';
import 'web_recording_helper.dart';

WebRecordingHelper getHelper() => WebRecordingHelperImpl();

class WebRecordingHelperImpl implements WebRecordingHelper {
  static const int _videoBitsPerSecond = 500 * 1000;
  static const int _audioBitsPerSecond = 64 * 1000;
  // Mobile Safari may discard a large in-memory recording before a long class
  // ends. Flush small chunks frequently enough that almost all recorded data
  // is already owned by Dart even if WebKit struggles during the final stop.
  static const Duration _dataFlushInterval = Duration(seconds: 15);
  static const Duration _finalDataFlushTimeout = Duration(seconds: 3);

  final List<web.Blob> _chunks = <web.Blob>[];
  web.MediaRecorder? _nativeRecorder;
  Completer<void>? _stopCompleter;
  Completer<void>? _pendingDataFlush;
  Timer? _dataFlushTimer;
  web.Blob? _recordedBlob;
  String _actualMimeType = 'video/webm';

  web.AudioContext? _audioContext;
  web.MediaStreamAudioDestinationNode? _destination;
  final List<web.MediaStreamAudioSourceNode> _sources = [];
  final Set<String> _mixedRemoteStreamIds = <String>{};

  @override
  String get recordedMimeType => _actualMimeType;

  @override
  int get recordedSizeBytes => _recordedBlob?.size ?? 0;

  String _getSupportedMimeType() {
    // Prefer a standards-based H.264/AAC MP4. Safari/iPhone can always play
    // this combination, while VP9 WebM recordings can remain on a loading
    // spinner or decode only their Opus audio on some iOS versions.
    //
    // `h264` and `opus` are not valid MP4 codec identifiers. Safari expects
    // RFC 6381 codec strings (avc1/mp4a), so keep those candidates first.
    final types = [
      'video/mp4;codecs=avc1.42E01E,mp4a.40.2',
      'video/mp4;codecs=avc1.42E01E',
      'video/mp4',
      // VP8 has wider iOS hardware/software support than VP9. Do not put
      // H.264 inside WebM; that non-standard pairing caused audio-only files.
      'video/webm;codecs=vp8,opus',
      'video/webm;codecs=vp8',
      'video/webm;codecs=vp9,opus',
      'video/webm',
    ];
    for (final type in types) {
      if (web.MediaRecorder.isTypeSupported(type)) {
        return type;
      }
    }
    return 'video/webm';
  }

  @override
  void start(
    dynamic mediaRecorder,
    dynamic stream, {
    List<dynamic>? remoteStreams,
  }) {
    _chunks.clear();
    _recordedBlob = null;
    _nativeRecorder = null;
    _dataFlushTimer?.cancel();
    _dataFlushTimer = null;
    _pendingDataFlush = null;
    _stopCompleter = Completer<void>();
    _sources.clear();
    _mixedRemoteStreamIds.clear();

    final mimeType = _getSupportedMimeType();
    _actualMimeType = mimeType;

    try {
      if (stream is MediaStreamWeb) {
        final localJsStream = stream.jsStream;

        // 1. Initialize AudioContext and Destination Node
        final audioContext = web.AudioContext();
        _audioContext = audioContext;

        // A suspended Web Audio graph produces a valid video with silent
        // audio. Recording starts from a user tap, so resume it immediately.
        audioContext.resume();

        final destination = audioContext.createMediaStreamDestination();
        _destination = destination;

        // 2. Add local microphone to mixer
        if (localJsStream.getAudioTracks().toDart.isNotEmpty) {
          final localSource = audioContext.createMediaStreamSource(
            localJsStream,
          );
          localSource.connect(destination);
          _sources.add(localSource);
        }

        // 3. Add initial remote streams (students) to mixer
        if (remoteStreams != null) {
          for (final rs in remoteStreams) {
            if (rs is MediaStreamWeb) {
              final remoteJsStream = rs.jsStream;
              if (remoteJsStream.getAudioTracks().toDart.isNotEmpty) {
                try {
                  final remoteSource = audioContext.createMediaStreamSource(
                    remoteJsStream,
                  );
                  remoteSource.connect(destination);
                  _sources.add(remoteSource);
                  _mixedRemoteStreamIds.add(rs.id);
                } catch (e) {
                  // ignore: avoid_print
                  print('Error mixing initial remote audio stream: $e');
                }
              }
            }
          }
        }

        // 4. Create combined MediaStream containing local video and mixed audio
        final mixedJsStream = web.MediaStream();

        // Add local video tracks
        for (final track in localJsStream.getVideoTracks().toDart) {
          mixedJsStream.addTrack(track);
        }

        // Add mixed audio tracks from destination node
        for (final track in destination.stream.getAudioTracks().toDart) {
          mixedJsStream.addTrack(track);
        }

        // Wrap the native mixed jsStream back to MediaStreamWeb
        final mixedStreamWeb = MediaStreamWeb(mixedJsStream, 'local');

        _startNativeRecorder(mixedStreamWeb.jsStream, mimeType);
      } else {
        // Fallback to recording local stream only if stream is not MediaStreamWeb
        throw StateError('Web recording requires a MediaStreamWeb.');
      }
    } catch (e) {
      // ignore: avoid_print
      print('Error starting web recording with audio mixing: $e');
      // Fallback
      try {
        if (stream is MediaStreamWeb) {
          _startNativeRecorder(stream.jsStream, mimeType);
        } else {
          rethrow;
        }
      } catch (_) {
        rethrow;
      }
    }
  }

  void _startNativeRecorder(web.MediaStream stream, String mimeType) {
    final recorder = web.MediaRecorder(
      stream,
      web.MediaRecorderOptions(
        mimeType: mimeType,
        videoBitsPerSecond: _videoBitsPerSecond,
        audioBitsPerSecond: _audioBitsPerSecond,
      ),
    );
    _nativeRecorder = recorder;
    // Browsers may normalize the requested value. Persist what the recorder
    // actually produced so Storage metadata and the file extension are true.
    if (recorder.mimeType.isNotEmpty) {
      _actualMimeType = recorder.mimeType;
    }

    void onData(web.Event event) {
      final data = event.getProperty<JSAny?>('data'.toJS);
      if (data != null) {
        final blob = data as web.Blob;
        if (blob.size > 0) {
          _chunks.add(blob);
        }
      }
      final pendingFlush = _pendingDataFlush;
      if (pendingFlush != null && !pendingFlush.isCompleted) {
        pendingFlush.complete();
      }
    }

    void onStop(web.Event event) {
      final completer = _stopCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }

    void onError(web.Event event) {
      final completer = _stopCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.completeError('Browser MediaRecorder failed.');
      }
    }

    recorder.addEventListener('dataavailable', onData.toJS);
    recorder.addEventListener('stop', onStop.toJS);
    recorder.addEventListener('error', onError.toJS);
    // Start without a WebKit timeslice. Older Safari versions produced broken
    // timestamps when a timeslice was passed directly to start(). Periodic
    // requestData() calls below still release the browser's growing internal
    // buffer, while the ordered Blob combination remains one recording.
    recorder.start();
    _dataFlushTimer = Timer.periodic(_dataFlushInterval, (_) {
      if (recorder.state != 'inactive') {
        try {
          recorder.requestData();
        } catch (e) {
          // A stop/error event can race this timer. The final stop still asks
          // the recorder for any data that has not already been emitted.
          // ignore: avoid_print
          print('Could not flush a web recording chunk: $e');
        }
      }
    });
  }

  @override
  void addRemoteStream(dynamic stream) {
    if (_audioContext != null &&
        _destination != null &&
        stream is MediaStreamWeb) {
      if (_mixedRemoteStreamIds.contains(stream.id)) {
        return;
      }
      final remoteJsStream = stream.jsStream;
      if (remoteJsStream.getAudioTracks().toDart.isNotEmpty) {
        try {
          final source = _audioContext!.createMediaStreamSource(remoteJsStream);
          source.connect(_destination!);
          _sources.add(source);
          // SFU video and audio can arrive in separate onTrack events. Mark a
          // stream mixed only after its audio track is actually available.
          _mixedRemoteStreamIds.add(stream.id);
        } catch (e) {
          // ignore: avoid_print
          print('Error adding remote stream dynamically to audio mixer: $e');
        }
      }
    }
  }

  @override
  Future<dynamic> stop() async {
    final recorder = _nativeRecorder;
    if (recorder == null) return null;

    _dataFlushTimer?.cancel();
    _dataFlushTimer = null;

    try {
      if (recorder.state != 'inactive') {
        // Safari sometimes takes too long to emit the final dataavailable
        // event for a long recording. Request and receive the current data
        // first, then stop the recorder. Previously a stop timeout could leave
        // _chunks empty and the class was marked finalization_failed.
        final flushCompleter = Completer<void>();
        _pendingDataFlush = flushCompleter;
        try {
          recorder.requestData();
          await flushCompleter.future.timeout(_finalDataFlushTimeout);
        } catch (e) {
          // stop() still emits its own final dataavailable event, so continue
          // when a browser does not support an explicit final flush reliably.
          // ignore: avoid_print
          print('Could not flush final web recording data: $e');
        } finally {
          if (identical(_pendingDataFlush, flushCompleter)) {
            _pendingDataFlush = null;
          }
        }
        recorder.stop();
      }
      await _stopCompleter?.future.timeout(const Duration(seconds: 20));
    } catch (e) {
      // ignore: avoid_print
      print('Error stopping web media recorder: $e');
    }

    // Clean up Web Audio API nodes to release resources and stop listeners
    for (final src in _sources) {
      try {
        src.disconnect();
      } catch (_) {}
    }
    _sources.clear();

    if (_audioContext != null) {
      try {
        _audioContext!.close();
      } catch (_) {}
      _audioContext = null;
    }
    _destination = null;
    _nativeRecorder = null;

    if (_chunks.isEmpty) return null;

    try {
      // Keep the result as a browser Blob. Converting a long video to
      // Uint8List duplicates the complete recording in memory and can crash
      // mobile Safari while the class is ending.
      _recordedBlob = web.Blob(
        _chunks.toJS,
        web.BlobPropertyBag(type: _actualMimeType),
      );
      _chunks.clear();
      return _recordedBlob;
    } catch (e) {
      // ignore: avoid_print
      print('Error finalizing recorded chunks: $e');
      return null;
    }
  }
}
