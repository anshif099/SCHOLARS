import 'dart:async';

import 'package:flutter/material.dart';

import '../services/web_pdf_renderer.dart';

class WebPdfPageView extends StatefulWidget {
  const WebPdfPageView({
    super.key,
    required this.url,
    required this.pageNumber,
    required this.reloadNonce,
    required this.onDocumentLoaded,
    required this.onRetry,
    required this.onOpenExternally,
  });

  final String url;
  final int pageNumber;
  final int reloadNonce;
  final ValueChanged<int> onDocumentLoaded;
  final VoidCallback onRetry;
  final VoidCallback onOpenExternally;

  @override
  State<WebPdfPageView> createState() => _WebPdfPageViewState();
}

class _WebPdfPageViewState extends State<WebPdfPageView> {
  static const int _maxRenderedDimension = 2000;

  WebPdfPageResult? _result;
  Object? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPage());
  }

  @override
  void didUpdateWidget(covariant WebPdfPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.pageNumber != widget.pageNumber ||
        oldWidget.reloadNonce != widget.reloadNonce) {
      if (oldWidget.url != widget.url) {
        disposeWebPdfDocument(oldWidget.url);
      }
      unawaited(_loadPage());
    }
  }

  Future<void> _loadPage() async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        _error = null;
      });
    }

    try {
      final result = await renderWebPdfPage(
        url: widget.url,
        pageNumber: widget.pageNumber,
        maxDimension: _maxRenderedDimension,
      ).timeout(const Duration(seconds: 45));
      if (!mounted || generation != _loadGeneration) {
        revokeWebPdfPageImage(result.imageUrl);
        return;
      }

      final oldResult = _result;
      setState(() {
        _result = result;
        _error = null;
      });
      if (oldResult != null) {
        revokeWebPdfPageImage(oldResult.imageUrl);
      }
      widget.onDocumentLoaded(result.pageCount);
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = error;
        });
      }
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    final result = _result;
    if (result != null) {
      revokeWebPdfPageImage(result.imageUrl);
    }
    disposeWebPdfDocument(widget.url);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.picture_as_pdf_rounded,
                size: 56,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 12),
              const Text(
                'PDF could not be displayed',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: widget.onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry PDF'),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenExternally,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open externally'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final result = _result;
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Image.network(
      result.imageUrl,
      key: ValueKey<String>(result.imageUrl),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => Center(
        child: Text(
          'PDF page image could not be displayed.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
