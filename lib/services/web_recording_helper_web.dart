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
  static const int _chunkIntervalMs = 10000;

  final List<web.Blob> _chunks = <web.Blob>[];
  web.MediaRecorder? _nativeRecorder;
  Completer<void>? _stopCompleter;
  web.Blob? _recordedBlob;
  String _actualMimeType = 'video/webm';

  web.AudioContext? _audioContext;
  web.MediaStreamAudioDestinationNode? _destination;
  final List<web.MediaStreamAudioSourceNode> _sources = [];

  @override
  String get recordedMimeType => _actualMimeType;

  @override
  int get recordedSizeBytes => _recordedBlob?.size ?? 0;

  String _getSupportedMimeType() {
    final types = [
      'video/webm;codecs=h264,opus',
      'video/webm;codecs=h264',
      'video/mp4;codecs=h264,opus',
      'video/mp4;codecs=h264',
      'video/webm;codecs=vp9,opus',
      'video/webm;codecs=vp8,opus',
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
    _stopCompleter = Completer<void>();
    _sources.clear();

    final mimeType = _getSupportedMimeType();
    _actualMimeType = mimeType;

    try {
      if (stream is MediaStreamWeb) {
        final localJsStream = stream.jsStream;

        // 1. Initialize AudioContext and Destination Node
        final audioContext = web.AudioContext();
        _audioContext = audioContext;

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

    void onData(web.Event event) {
      final data = event.getProperty<JSAny?>('data'.toJS);
      if (data != null) {
        final blob = data as web.Blob;
        if (blob.size > 0) {
          _chunks.add(blob);
        }
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
    recorder.start(_chunkIntervalMs);
  }

  @override
  void addRemoteStream(dynamic stream) {
    if (_audioContext != null &&
        _destination != null &&
        stream is MediaStreamWeb) {
      final remoteJsStream = stream.jsStream;
      if (remoteJsStream.getAudioTracks().toDart.isNotEmpty) {
        try {
          final source = _audioContext!.createMediaStreamSource(remoteJsStream);
          source.connect(_destination!);
          _sources.add(source);
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

    try {
      if (recorder.state != 'inactive') {
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
