import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/pages/video_player_page.dart';

void main() {
  test('presentation events are normalized, filtered, and sorted', () {
    final events = VideoPlayerPage.parsePresentationEvents(<String, dynamic>{
      '2': <String, dynamic>{
        'offset_ms': 5000,
        'action': 'hide',
      },
      '0': <String, dynamic>{
        'offset_ms': 1200,
        'action': 'show',
        'url': 'https://example.com/note.png',
        'file_type': 'image',
        'page': 1,
      },
      '1': <String, dynamic>{
        'offset_ms': 2500.0,
        'action': 'show',
        'url': 'https://example.com/slides.pdf',
        'file_type': 'pdf',
        'page': 3.0,
      },
      'invalid': <String, dynamic>{
        'offset_ms': 0,
        'action': 'show',
        'url': '',
      },
    });

    expect(events, hasLength(3));
    expect(events.map((event) => event['offset_ms']), <int>[1200, 2500, 5000]);
    expect(events[1]['page'], 3);
    expect(events.last['action'], 'hide');
  });
}
