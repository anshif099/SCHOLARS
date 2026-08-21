import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/web_pdf_renderer.dart';

class WebPdfPageView extends StatefulWidget {
  const WebPdfPageView({
    super.key,
    required this.url,
    this.data,
    required this.pageNumber,
    required this.reloadNonce,
    required this.onDocumentLoaded,
    required this.onRetry,
  });

  final String url;
  final Uint8List? data;
  final int pageNumber;
  final int reloadNonce;
  final ValueChanged<int> onDocumentLoaded;
  final VoidCallback onRetry;

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
        !identical(oldWidget.data, widget.data) ||
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
        data: widget.data,
      ).timeout(const Duration(seconds: 45));
      if (!mounted || generation != _loadGeneration) {
        return;
      }

      setState(() {
        _result = result;
        _error = null;
      });
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

    return Image.memory(
      result.imageBytes,
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
