import 'dart:typed_data';

class WebPdfPageResult {
  const WebPdfPageResult({required this.imageBytes, required this.pageCount});

  final Uint8List imageBytes;
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

void disposeWebPdfDocument(String url) {}
