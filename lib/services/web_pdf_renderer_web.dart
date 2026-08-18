import 'dart:js_interop';

import 'package:web/web.dart' as web;

class WebPdfPageResult {
  const WebPdfPageResult({required this.imageUrl, required this.pageCount});

  final String imageUrl;
  final int pageCount;
}

@JS('scholarsRenderPdfPage')
external JSPromise<_WebPdfPageResult> _renderPdfPage(
  String url,
  int pageNumber,
  int maxDimension,
);

@JS('scholarsRevokePdfPageImage')
external void _revokePdfPageImage(String imageUrl);

@JS('scholarsDisposePdfDocument')
external void _disposePdfDocument(String url);

@JS()
extension type _WebPdfPageResult(JSObject _) implements JSObject {
  external String get imageUrl;
  external int get pageCount;
}

bool get shouldUseWebPdfRenderer {
  final navigator = web.window.navigator;
  final userAgent = navigator.userAgent;
  final isIos = RegExp(
    r'iPad|iPhone|iPod',
    caseSensitive: false,
  ).hasMatch(userAgent);
  final isDesktopModeIpad =
      navigator.platform == 'MacIntel' && navigator.maxTouchPoints > 1;
  return isIos || isDesktopModeIpad;
}

Future<WebPdfPageResult> renderWebPdfPage({
  required String url,
  required int pageNumber,
  required int maxDimension,
}) async {
  final result = await _renderPdfPage(url, pageNumber, maxDimension).toDart;
  return WebPdfPageResult(
    imageUrl: result.imageUrl,
    pageCount: result.pageCount,
  );
}

void revokeWebPdfPageImage(String imageUrl) {
  if (imageUrl.startsWith('blob:')) {
    _revokePdfPageImage(imageUrl);
  }
}

void disposeWebPdfDocument(String url) => _disposePdfDocument(url);
