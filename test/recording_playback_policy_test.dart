import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/services/recording_playback_policy.dart';

void main() {
  group('recording playback policy', () {
    test('keeps an uploaded MP4 playable while normalization runs', () {
      final recording = <String, dynamic>{
        'compatibility_status': 'converting',
        'mime_type': 'video/mp4',
        'video_url': 'https://example.test/class.mp4',
      };

      expect(
        isIOSRecordingPreparationPending(recording, isIOSWeb: true),
        isFalse,
      );
    });

    test('blocks a pending WebM recording on iPhone web', () {
      final recording = <String, dynamic>{
        'compatibility_status': 'waiting',
        'mime_type': 'video/webm',
        'video_url': 'https://example.test/class.webm',
      };

      expect(
        isIOSRecordingPreparationPending(recording, isIOSWeb: true),
        isTrue,
      );
    });

    test('does not apply the iPhone WebM block on other platforms', () {
      final recording = <String, dynamic>{
        'compatibility_status': 'converting',
        'mime_type': 'video/webm',
      };

      expect(
        isIOSRecordingPreparationPending(recording, isIOSWeb: false),
        isFalse,
      );
    });
  });
}
