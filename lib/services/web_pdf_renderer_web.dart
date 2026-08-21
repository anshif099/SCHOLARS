import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'mobile_web_pdf_policy.dart';

class WebPdfPageResult {
  const WebPdfPageResult({required this.imageBytes, required this.pageCount});

  final Uint8List imageBytes;
  final int pageCount;
}

@JS('scholarsRenderPdfPage')
external JSPromise<_WebPdfPageResult> _renderPdfPage(
  String url,
  int pageNumber,
  int maxDimension,
  JSUint8Array? data,
);

@JS('scholarsDisposePdfDocument')
external void _disposePdfDocument(String url);

@JS()
extension type _WebPdfPageResult(JSObject _) implements JSObject {
  external JSUint8Array get imageBytes;
  external int get pageCount;
}

bool get shouldUseWebPdfRenderer {
  final navigator = web.window.navigator;
  return shouldUseMobileWebPdfRenderer(
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    maxTouchPoints: navigator.maxTouchPoints,
  );
}

Future<void>? _rendererLoadFuture;

bool get _isRendererLoaded {
  final version = globalContext.getProperty<JSNumber?>(
    'scholarsPdfRendererVersion'.toJS,
  );
  return version?.toDartInt == 3;
}

Future<void> _ensureRendererLoaded() {
  if (_isRendererLoaded) {
    return Future<void>.value();
  }
  return _rendererLoadFuture ??= _loadRendererScript();
}

Future<void> _loadRendererScript() async {
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..type = 'text/javascript'
    ..src = Uri.parse(
      web.document.baseURI,
    ).resolve('pdfjs/pdf_renderer.js?v=3').toString();
  final completer = Completer<void>();
  final loadSubscription = script.onLoad.listen((_) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  });
  final errorSubscription = script.onError.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError('The in-app PDF renderer could not be loaded.'),
      );
    }
  });
  web.document.querySelector('head')!.appendChild(script);
  try {
    await completer.future.timeout(const Duration(seconds: 15));
    if (!_isRendererLoaded) {
      throw StateError('The in-app PDF renderer did not initialize.');
    }
  } catch (_) {
    _rendererLoadFuture = null;
    rethrow;
  } finally {
    await loadSubscription.cancel();
    await errorSubscription.cancel();
  }
}

Future<WebPdfPageResult> renderWebPdfPage({
  required String url,
  required int pageNumber,
  required int maxDimension,
  Uint8List? data,
}) async {
  await _ensureRendererLoaded();
  final result = await _renderPdfPage(
    url,
    pageNumber,
    maxDimension,
    data?.toJS,
  ).toDart;
  return WebPdfPageResult(
    imageBytes: result.imageBytes.toDart,
    pageCount: result.pageCount,
  );
}

void disposeWebPdfDocument(String url) => _disposePdfDocument(url);
