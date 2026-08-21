import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/services/mobile_web_pdf_policy.dart';

void main() {
  test('uses the safe PDF renderer on iPhone and iPad browsers', () {
    expect(
      shouldUseMobileWebPdfRenderer(
        userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X)',
        platform: 'iPhone',
        maxTouchPoints: 5,
      ),
      isTrue,
    );
    expect(
      shouldUseMobileWebPdfRenderer(
        userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)',
        platform: 'MacIntel',
        maxTouchPoints: 5,
      ),
      isTrue,
    );
  });

  test('uses the safe PDF renderer on Android browsers', () {
    expect(
      shouldUseMobileWebPdfRenderer(
        userAgent:
            'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36',
        platform: 'Linux armv8l',
        maxTouchPoints: 5,
      ),
      isTrue,
    );
  });

  test('keeps the existing renderer on desktop browsers', () {
    expect(
      shouldUseMobileWebPdfRenderer(
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        platform: 'Win32',
        maxTouchPoints: 0,
      ),
      isFalse,
    );
  });
}
