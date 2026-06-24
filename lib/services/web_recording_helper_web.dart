import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:dart_webrtc/src/media_stream_impl.dart';
import 'web_recording_helper.dart';

WebRecordingHelper getHelper() => WebRecordingHelperImpl();

class WebRecordingHelperImpl implements WebRecordingHelper {
  final List<dynamic> _chunks = [];
  dynamic _mediaRecorder;
  String _actualMimeType = 'video/webm';

  web.AudioContext? _audioContext;
  web.MediaStreamAudioDestinationNode? _destination;
  final List<web.MediaStreamAudioSourceNode> _sources = [];

  @override
  String get recordedMimeType => _actualMimeType;

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
      if (html.MediaRecorder.isTypeSupported(type)) {
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
    _mediaRecorder = mediaRecorder;
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
          final localSource = audioContext.createMediaStreamSource(localJsStream);
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
                  final remoteSource = audioContext.createMediaStreamSource(remoteJsStream);
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

        mediaRecorder.startWeb(
          mixedStreamWeb,
          onDataChunk: (dynamic blob, bool isLastOne) {
            if (blob != null) {
              _chunks.add(blob);
            }
          },
          mimeType: mimeType,
          timeSlice: 1000,
        );
      } else {
        // Fallback to recording local stream only if stream is not MediaStreamWeb
        mediaRecorder.startWeb(
          stream,
          onDataChunk: (dynamic blob, bool isLastOne) {
            if (blob != null) {
              _chunks.add(blob);
            }
          },
          mimeType: mimeType,
          timeSlice: 1000,
        );
      }
    } catch (e) {
      // ignore: avoid_print
      print('Error starting web recording with audio mixing: $e');
      // Fallback
      try {
        mediaRecorder.startWeb(
          stream,
          onDataChunk: (dynamic blob, bool isLastOne) {
            if (blob != null) {
              _chunks.add(blob);
            }
          },
          mimeType: mimeType,
          timeSlice: 1000,
        );
      } catch (_) {}
    }
  }

  @override
  void addRemoteStream(dynamic stream) {
    if (_audioContext != null && _destination != null && stream is MediaStreamWeb) {
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
  Future<Uint8List?> stop() async {
    if (_mediaRecorder == null) return null;

    try {
      await _mediaRecorder.stop();
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

    if (_chunks.isEmpty) return null;

    final completer = Completer<Uint8List?>();
    try {
      final finalBlob = html.Blob(_chunks, _actualMimeType);
      final reader = html.FileReader();

      reader.onLoadEnd.listen((e) {
        final result = reader.result;
        if (result is Uint8List) {
          completer.complete(result);
        } else if (result is ByteBuffer) {
          completer.complete(result.asUint8List());
        } else {
          completer.complete(null);
        }
      });

      reader.onError.listen((e) {
        completer.completeError('Error reading recorded chunks: ${reader.error}');
      });

      reader.readAsArrayBuffer(finalBlob);
    } catch (e) {
      // ignore: avoid_print
      print('Error converting chunks to bytes: $e');
      completer.complete(null);
    }

    return completer.future;
  }
}
