import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/components/universal_image.dart';
import 'package:scholars/components/universal_image_web.dart' as web_image;

void main() {
  testWidgets('UniversalImage forwards its presentation options', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 320,
          height: 180,
          child: UniversalImage(
            imageUrl:
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            fit: BoxFit.contain,
            errorBuilder: _emptyImageError,
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
  });

  test('web renderer uses Flutter managed cross-origin image composition', () {
    final image = web_image.buildPlatformImage(
      imageUrl: 'https://example.com/shared-note.png',
      fit: BoxFit.contain,
    );

    expect(image, isA<Image>());
    final provider = (image as Image).image as NetworkImage;
    expect(provider.webHtmlElementStrategy, WebHtmlElementStrategy.prefer);
  });
}

Widget _emptyImageError(
  BuildContext context,
  Object error,
  StackTrace? stackTrace,
) {
  return const SizedBox.shrink();
}
