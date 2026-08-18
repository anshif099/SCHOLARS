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
}) {
  throw UnsupportedError(
    'The web PDF renderer is only available in a browser.',
  );
}

void revokeWebPdfPageImage(String imageUrl) {}

void disposeWebPdfDocument(String url) {}
