import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/pages/video_player_page.dart';

void main() {
  test('presentation events are normalized, filtered, and sorted', () {
    final events = VideoPlayerPage.parsePresentationEvents(<String, dynamic>{
      '2': <String, dynamic>{'offset_ms': 5000, 'action': 'hide'},
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
      'invalid': <String, dynamic>{'offset_ms': 0, 'action': 'show', 'url': ''},
    });

    expect(events, hasLength(3));
    expect(events.map((event) => event['offset_ms']), <int>[1200, 2500, 5000]);
    expect(events[1]['page'], 3);
    expect(events.last['action'], 'hide');
  });

  test('drawing and zoom state can be rebuilt at any playback position', () {
    final stroke = <String, dynamic>{
      'points': <Map<String, double>>[
        <String, double>{'x': 0.1, 'y': 0.2},
        <String, double>{'x': 0.4, 'y': 0.5},
      ],
      'color': 0xFFFF0000,
      'stroke_width': 4.0,
    };
    final events = VideoPlayerPage.parsePresentationEvents(
      <Map<String, dynamic>>[
        <String, dynamic>{
          'offset_ms': 0,
          'sequence': 0,
          'action': 'show',
          'url': 'https://example.com/slides.pdf',
          'file_type': 'pdf',
          'page': 2,
          'strokes': <dynamic>[],
        },
        <String, dynamic>{
          'offset_ms': 1000,
          'sequence': 1,
          'action': 'stroke',
          'url': 'https://example.com/slides.pdf',
          'page': 2,
          'stroke': stroke,
        },
        <String, dynamic>{
          'offset_ms': 2000,
          'sequence': 2,
          'action': 'view',
          'url': 'https://example.com/slides.pdf',
          'page': 2,
          'zoom': 2.5,
          'pan_x': -0.25,
          'pan_y': -0.1,
        },
        <String, dynamic>{
          'offset_ms': 3000,
          'sequence': 3,
          'action': 'clear',
          'url': 'https://example.com/slides.pdf',
          'page': 2,
        },
        <String, dynamic>{
          'offset_ms': 4000,
          'sequence': 4,
          'action': 'stroke',
          'url': 'https://example.com/slides.pdf',
          'page': 2,
          'stroke': stroke,
        },
        <String, dynamic>{'offset_ms': 5000, 'sequence': 5, 'action': 'hide'},
      ],
    );

    final drawn = VideoPlayerPage.resolvePresentationAt(events, 2500)!;
    expect(drawn['zoom'], 2.5);
    expect(drawn['pan_x'], -0.25);
    expect(drawn['strokes'], hasLength(1));

    final cleared = VideoPlayerPage.resolvePresentationAt(events, 3500)!;
    expect(cleared['strokes'], isEmpty);

    final redrawn = VideoPlayerPage.resolvePresentationAt(events, 4500)!;
    expect(redrawn['strokes'], hasLength(1));
    expect(VideoPlayerPage.resolvePresentationAt(events, 5500), isNull);
  });

  test('incremental events for another page do not leak into playback', () {
    final events = VideoPlayerPage.parsePresentationEvents(
      <Map<String, dynamic>>[
        <String, dynamic>{
          'offset_ms': 0,
          'action': 'show',
          'url': 'https://example.com/slides.pdf',
          'file_type': 'pdf',
          'page': 1,
        },
        <String, dynamic>{
          'offset_ms': 100,
          'action': 'stroke',
          'url': 'https://example.com/slides.pdf',
          'page': 2,
          'stroke': <String, dynamic>{
            'points': <Map<String, double>>[
              <String, double>{'x': 0.2, 'y': 0.3},
            ],
            'color': 0xFF0000FF,
            'stroke_width': 4,
          },
        },
      ],
    );

    final state = VideoPlayerPage.resolvePresentationAt(events, 200)!;
    expect(state['strokes'], isEmpty);
  });
}
