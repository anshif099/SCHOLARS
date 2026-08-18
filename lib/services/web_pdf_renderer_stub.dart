import 'dart:typed_data';

class WebPdfPageResult {
  const WebPdfPageResult({required this.imageUrl, required this.pageCount});

  final String imageUrl;
  final int pageCount;
}

bool get shouldUseWebPdfRenderer => false;

Future<WebPdfPageResult> renderWebPdfPage({
  required String url,
  required int pageNumber,
  required int maxDimension,
  Uint8List? data,
}) {
  throw UnsupportedError(
    'The web PDF renderer is only available in a browser.',
  );
}

void revokeWebPdfPageImage(String imageUrl) {}

void disposeWebPdfDocument(String url) {}
