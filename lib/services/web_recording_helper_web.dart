import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'web_recording_helper.dart';

WebRecordingHelper getHelper() => WebRecordingHelperImpl();

class WebRecordingHelperImpl implements WebRecordingHelper {
  final List<dynamic> _chunks = [];
  dynamic _mediaRecorder;

  @override
  void start(dynamic mediaRecorder, dynamic stream) {
    _chunks.clear();
    _mediaRecorder = mediaRecorder;

    try {
      mediaRecorder.startWeb(
        stream,
        onDataChunk: (dynamic blob, bool isLastOne) {
          if (blob != null) {
            _chunks.add(blob);
          }
        },
        mimeType: 'video/webm',
        timeSlice: 1000,
      );
    } catch (e) {
      // ignore: avoid_print
      print('Error starting web recording: $e');
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

    if (_chunks.isEmpty) return null;

    final completer = Completer<Uint8List?>();
    try {
      final finalBlob = html.Blob(_chunks, 'video/webm');
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
