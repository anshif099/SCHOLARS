import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

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
  JSUint8Array? data,
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

Future<void>? _rendererLoadFuture;

bool get _isRendererLoaded {
  final version = globalContext.getProperty<JSNumber?>(
    'scholarsPdfRendererVersion'.toJS,
  );
  return version?.toDartInt == 2;
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
    ).resolve('pdfjs/pdf_renderer.js?v=2').toString();
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
