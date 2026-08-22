import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../services/video_web_helper.dart';
import '../theme/app_theme.dart';
import '../components/universal_image.dart';
import '../components/web_pdf_page_view.dart';
import '../services/web_pdf_renderer.dart';
import 'webm_video_player_page.dart';

class VideoPlayerPage extends StatefulWidget {
  /// Firebase Storage download URL (preferred).
  final String? videoUrl;

  /// Legacy Base64-encoded video data (fallback for old recordings).
  final String? videoBase64;

  /// MIME type of the video (e.g. 'video/mp4', 'video/webm').
  /// Used to immediately route WebM to the WebView-based player on native.
  final String? mimeType;

  final String title;

  /// Timestamped PDF/image changes captured while the live class was recorded.
  final List<Map<String, dynamic>> presentationEvents;

  const VideoPlayerPage({
    super.key,
    this.videoUrl,
    this.videoBase64,
    this.mimeType,
    required this.title,
    this.presentationEvents = const <Map<String, dynamic>>[],
  });

  static List<Map<String, dynamic>> parsePresentationEvents(dynamic raw) {
    final values = raw is List
        ? raw.where((value) => value != null)
        : raw is Map
        ? raw.values
        : const <dynamic>[];
    final events = <Map<String, dynamic>>[];

    for (final value in values) {
      if (value is! Map) continue;
      final event = Map<String, dynamic>.from(value);
      event['offset_ms'] = (event['offset_ms'] as num? ?? 0).toInt();
      event['page'] = (event['page'] as num? ?? 1).toInt();
      final action = event['action']?.toString();
      if (action == 'hide' ||
          (action == 'show' &&
              event['url'] != null &&
              event['url'].toString().isNotEmpty)) {
        events.add(event);
      }
    }

    events.sort(
      (a, b) => (a['offset_ms'] as int).compareTo(b['offset_ms'] as int),
    );
    return events;
  }

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  static const Duration _initializationTimeout = Duration(seconds: 15);
  static const Duration _bufferingTimeout = Duration(seconds: 30);
  static const Duration _disposalTimeout = Duration(seconds: 3);
  static const int _maxPresentationPdfBytes = 100 * 1024 * 1024;

  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  Timer? _bufferingTimer;
  Duration _lastPlaybackPosition = Duration.zero;
  bool _isLoading = true;
  String? _errorMessage;
  String? _tempFilePath;
  late final List<Map<String, dynamic>> _presentationEvents;
  int _activePresentationIndex = -1;
  Map<String, dynamic>? _activePresentation;
  PDFViewController? _presentationPdfController;
  String? _presentationPdfUrl;
  String? _presentationPdfPath;
  Uint8List? _presentationPdfBytes;
  Object? _presentationPdfLoadError;
  bool _isLoadingPresentationPdf = false;
  int _pdfDownloadGeneration = 0;
  int _webPdfReloadNonce = 0;

  @override
  void initState() {
    super.initState();
    _presentationEvents =
        List<Map<String, dynamic>>.from(widget.presentationEvents)..sort(
          (a, b) => ((a['offset_ms'] as num?)?.toInt() ?? 0).compareTo(
            (b['offset_ms'] as num?)?.toInt() ?? 0,
          ),
        );
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    // Prefer URL-based playback (Firebase Storage)
    if (widget.videoUrl != null && widget.videoUrl!.isNotEmpty) {
      await _initFromUrl(widget.videoUrl!);
      return;
    }

    // Fallback: legacy Base64 playback
    if (widget.videoBase64 != null && widget.videoBase64!.isNotEmpty) {
      await _initFromBase64(widget.videoBase64!);
      return;
    }

    setState(() {
      _isLoading = false;
      _errorMessage = 'No video data available for this recording.';
    });
  }

  /// Returns true when the video is WebM and must be played via WebView.
  bool _isWebmUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.webm') || lower.contains('webm');
  }

  bool get _isWebmRecording {
    final mime = widget.mimeType?.toLowerCase() ?? '';
    return mime.contains('webm') ||
        (widget.videoUrl != null && _isWebmUrl(widget.videoUrl!));
  }

  bool get _isIOSWebmRecording =>
      kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && _isWebmRecording;

  bool _needsWebmPlayer(String url) {
    if (kIsWeb) return false; // Web browser handles WebM natively
    // Check explicit mime_type first; fall back to URL inspection
    return _isWebmRecording;
  }

  Future<void> _initFromUrl(String url) async {
    // On native platforms WebM (VP8/VP9) is unsupported by video_player.
    // Navigate to the WebView-based player which handles it.
    if (_needsWebmPlayer(url)) {
      if (!mounted) return;
      // Replace this page with the WebView player so Back works correctly
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => WebmVideoPlayerPage(
              videoUrl: url,
              title: widget.title,
              presentationEvents: _presentationEvents,
            ),
          ),
        );
      });
      return;
    }

    try {
      _videoPlayerController = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      await _videoPlayerController!.initialize().timeout(
        _initializationTimeout,
      );
      await _videoPlayerController!.setLooping(false);
      await _videoPlayerController!.setPlaybackSpeed(1);
      if (!mounted) {
        await _disposePlayerControllers();
        return;
      }
      _createChewieController();
      setState(() => _isLoading = false);
    } catch (e) {
      await _disposePlayerControllers();
      // A Blob contains the same codec and cannot make WebM decodable on iOS.
      // It also downloads the entire class before retrying, which is especially
      // expensive on mobile. Keep the Blob fallback for ordinary MP4/network
      // failures only.
      if (kIsWeb && !_isWebmRecording) {
        try {
          final blobUrl = await VideoWebHelper().fetchBlobUrl(url);
          _videoPlayerController = VideoPlayerController.networkUrl(
            Uri.parse(blobUrl),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
          );
          await _videoPlayerController!.initialize().timeout(
            _initializationTimeout,
          );
          await _videoPlayerController!.setLooping(false);
          await _videoPlayerController!.setPlaybackSpeed(1);
          if (!mounted) {
            await _disposePlayerControllers();
            return;
          }
          _createChewieController();
          setState(() => _isLoading = false);
          return;
        } catch (blobError) {
          debugPrint('Blob URL fallback failed: $blobError');
          await _disposePlayerControllers();
        }
      }

      debugPrint(
        'Recorded video initialization failed '
        '(host: ${Uri.tryParse(url)?.host}, mime: ${widget.mimeType}): $e',
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = _isIOSWebmRecording
            ? 'This older recording is WebM/VP9, which this iPhone cannot decode reliably. It must be converted to MP4 before it can play here.'
            : 'The video server did not respond or this device could not decode the recording.';
      });
    }
  }

  Future<void> _initFromBase64(String base64Data) async {
    try {
      // Decode Base64 to bytes and write to a temp file
      final bytes = base64Decode(base64Data);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
        '${tempDir.path}/playback_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      await tempFile.writeAsBytes(bytes);
      _tempFilePath = tempFile.path;

      _videoPlayerController = VideoPlayerController.file(tempFile);
      await _prepareVideoController();
    } catch (e) {
      await _disposePlayerControllers();
      debugPrint('Legacy recorded video initialization failed: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'The saved recording could not be opened.';
      });
    }
  }

  Future<void> _prepareVideoController() async {
    await _videoPlayerController!.initialize().timeout(_initializationTimeout);
    await _videoPlayerController!.setLooping(false);
    await _videoPlayerController!.setPlaybackSpeed(1);
    if (!mounted) {
      await _disposePlayerControllers();
      return;
    }
    _createChewieController();
    setState(() => _isLoading = false);
  }

  Future<void> _disposePlayerControllers() async {
    _bufferingTimer?.cancel();
    _bufferingTimer = null;

    final chewieController = _chewieController;
    final videoController = _videoPlayerController;
    _chewieController = null;
    _videoPlayerController = null;

    chewieController?.dispose();
    if (videoController != null) {
      videoController.removeListener(_handlePlaybackProgress);
      try {
        await videoController.dispose().timeout(_disposalTimeout);
      } on TimeoutException {
        debugPrint('Recorded video controller disposal timed out.');
      }
    }
  }

  Future<void> _retryPlayback() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    await _disposePlayerControllers();
    if (!mounted) return;
    await _initializePlayer();
  }

  void _openCompatibilityPlayer() {
    final url = widget.videoUrl;
    if (url == null || url.isEmpty) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => WebmVideoPlayerPage(
          videoUrl: url,
          title: widget.title,
          presentationEvents: _presentationEvents,
        ),
      ),
    );
  }

  Future<void> _openInBrowser() async {
    final url = widget.videoUrl;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the video in a browser.')),
      );
    }
  }

  void _createChewieController() {
    final aspectRatio = _videoPlayerController!.value.aspectRatio;

    _chewieController = ChewieController(
      videoPlayerController: _videoPlayerController!,
      autoPlay: !kIsWeb,
      looping: false,
      aspectRatio: aspectRatio <= 0 ? 4 / 3 : aspectRatio,
      allowPlaybackSpeedChanging: true,
      playbackSpeeds: const [0.75, 1, 1.25, 1.5],
      progressIndicatorDelay: const Duration(milliseconds: 300),
      materialProgressColors: ChewieProgressColors(
        playedColor: AppColors.accentRed,
        handleColor: AppColors.accentRed,
        backgroundColor: Colors.grey,
        bufferedColor: Colors.white,
      ),
      placeholder: Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      ),
      bufferingBuilder: (context) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      errorBuilder: (context, errorMessage) {
        return Center(
          child: Text(
            errorMessage,
            style: const TextStyle(color: Colors.white),
          ),
        );
      },
    );

    _lastPlaybackPosition = Duration.zero;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    _videoPlayerController!.addListener(_handlePlaybackProgress);
    _handlePlaybackProgress();
  }

  void _handlePlaybackProgress() {
    final controller = _videoPlayerController;
    if (!mounted || controller == null) {
      return;
    }

    final value = controller.value;
    if (value.hasError) {
      _showPlaybackError(
        'This recording could not be played on this device or network.',
        details: value.errorDescription,
      );
      return;
    }
    if (!value.isInitialized) return;

    _monitorBuffering(controller, value);

    final positionMs = value.position.inMilliseconds;
    var eventIndex = -1;
    for (var index = 0; index < _presentationEvents.length; index++) {
      final offset =
          (_presentationEvents[index]['offset_ms'] as num?)?.toInt() ?? 0;
      if (offset > positionMs) break;
      eventIndex = index;
    }

    if (eventIndex == _activePresentationIndex) return;
    final event = eventIndex >= 0 ? _presentationEvents[eventIndex] : null;
    final activeEvent = event?['action'] == 'show' ? event : null;

    setState(() {
      _activePresentationIndex = eventIndex;
      _activePresentation = activeEvent;
    });

    if (activeEvent?['file_type']?.toString() == 'pdf') {
      unawaited(_preparePresentationPdf(activeEvent!));
    }
  }

  void _monitorBuffering(
    VideoPlayerController controller,
    VideoPlayerValue value,
  ) {
    if (_errorMessage != null) {
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
      return;
    }

    final madeProgress =
        value.position > _lastPlaybackPosition + const Duration(seconds: 1);
    if (madeProgress) {
      _lastPlaybackPosition = value.position;
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
    }

    if (!value.isBuffering) {
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
      return;
    }

    _bufferingTimer ??= Timer(_bufferingTimeout, () {
      if (!mounted ||
          !identical(_videoPlayerController, controller) ||
          !controller.value.isBuffering) {
        return;
      }
      _showPlaybackError(
        _isIOSWebmRecording
            ? 'This WebM/VP9 recording cannot be decoded reliably by this iPhone. Convert it to MP4 to play it here.'
            : 'The video stopped buffering. Try again, switch networks, or use the compatibility player.',
      );
    });
  }

  void _showPlaybackError(String message, {String? details}) {
    if (_errorMessage != null || !mounted) return;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    if (details != null && details.isNotEmpty) {
      debugPrint('Recorded video playback error: $details');
    }
    unawaited(_videoPlayerController?.pause());
    setState(() {
      _isLoading = false;
      _errorMessage = message;
    });
  }

  Future<void> _preparePresentationPdf(Map<String, dynamic> event) async {
    final url = event['url']?.toString();
    if (url == null || url.isEmpty) return;
    final page = ((event['page'] as num?)?.toInt() ?? 1).clamp(1, 1000000);

    if (_presentationPdfUrl == url) {
      if (_isLoadingPresentationPdf) return;
      if (kIsWeb && _presentationPdfBytes != null) return;
      if (!kIsWeb && _presentationPdfPath != null) {
        await _presentationPdfController?.setPage(page - 1);
        return;
      }
    }

    final previousPdfPath = _presentationPdfUrl != url
        ? _presentationPdfPath
        : null;
    final generation = ++_pdfDownloadGeneration;
    if (mounted) {
      setState(() {
        if (_presentationPdfUrl != url) {
          _presentationPdfBytes = null;
          _presentationPdfPath = null;
        }
        _presentationPdfUrl = url;
        _presentationPdfLoadError = null;
        _isLoadingPresentationPdf = true;
      });
    }
    if (!kIsWeb && previousPdfPath != null) {
      try {
        await File(previousPdfPath).delete();
      } catch (_) {}
    }

    if (kIsWeb) {
      try {
        final bytes = await FirebaseStorage.instance
            .refFromURL(url)
            .getData(_maxPresentationPdfBytes);
        if (bytes == null) {
          throw StateError('Firebase Storage returned no PDF data.');
        }
        if (!mounted || generation != _pdfDownloadGeneration) return;
        setState(() {
          _presentationPdfBytes = bytes;
          _presentationPdfLoadError = null;
          _isLoadingPresentationPdf = false;
        });
      } catch (error) {
        debugPrint('Recorded presentation PDF could not be loaded: $error');
        if (mounted && generation == _pdfDownloadGeneration) {
          setState(() {
            _presentationPdfLoadError = error;
            _isLoadingPresentationPdf = false;
          });
        }
      }
      return;
    }

    HttpClient? client;
    try {
      client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('PDF download failed (${response.statusCode})');
      }
      final bytes = await consolidateHttpClientResponseBytes(response);
      final tempDir = await getTemporaryDirectory();
      final file = File(
        '${tempDir.path}/recorded_presentation_${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);

      if (!mounted || generation != _pdfDownloadGeneration) {
        try {
          await file.delete();
        } catch (_) {}
        return;
      }

      final previousPath = _presentationPdfPath;
      setState(() {
        _presentationPdfPath = file.path;
        _presentationPdfLoadError = null;
        _isLoadingPresentationPdf = false;
      });
      if (previousPath != null && previousPath != file.path) {
        try {
          await File(previousPath).delete();
        } catch (_) {}
      }
    } catch (error) {
      debugPrint('Recorded presentation PDF could not be loaded: $error');
      if (mounted && generation == _pdfDownloadGeneration) {
        setState(() {
          _presentationPdfLoadError = error;
          _isLoadingPresentationPdf = false;
        });
      }
    } finally {
      client?.close(force: true);
    }
  }

  Widget _buildPlayer() {
    final chewieController = _chewieController;
    if (chewieController == null ||
        !chewieController.videoPlayerController.value.isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }

    if (_presentationEvents.isEmpty) {
      return Chewie(controller: chewieController);
    }

    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: Chewie(controller: chewieController)),
          if (_activePresentation != null)
            Positioned.fill(
              bottom: 72,
              child: IgnorePointer(
                child: _buildPresentation(_activePresentation!),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPresentation(Map<String, dynamic> event) {
    final type = event['file_type']?.toString() ?? 'image';
    final url = event['url']?.toString() ?? '';
    final name = event['file_name']?.toString() ?? 'Shared note';
    final page = ((event['page'] as num?)?.toInt() ?? 1).clamp(1, 1000000);

    return ColoredBox(
      color: const Color(0xFF111318),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 48, 12, 12),
              child: type == 'pdf'
                  ? _buildRecordedPdf(url, page)
                  : UniversalImage(
                      imageUrl: url,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildPresentationError('Shared image unavailable'),
                    ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 8,
            child: Row(
              children: [
                const Icon(
                  Icons.present_to_all_rounded,
                  color: Colors.white70,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (type == 'pdf')
                  Text(
                    'Page $page',
                    style: GoogleFonts.poppins(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordedPdf(String url, int page) {
    if (kIsWeb) {
      if (_presentationPdfUrl == url && _presentationPdfLoadError != null) {
        return _buildPresentationError('Shared PDF unavailable');
      }
      final pdfBytes = _presentationPdfUrl == url
          ? _presentationPdfBytes
          : null;
      if (_isLoadingPresentationPdf || pdfBytes == null) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      }
      return ColoredBox(
        color: Colors.white,
        child: WebPdfPageView(
          key: ValueKey<String>('recorded-web-pdf-$url'),
          url: url,
          data: pdfBytes,
          pageNumber: page,
          reloadNonce: _webPdfReloadNonce,
          onDocumentLoaded: (_) {},
          onRetry: () => _retryPresentationPdf(url, page),
        ),
      );
    }
    if (_presentationPdfUrl == url && _presentationPdfLoadError != null) {
      return _buildPresentationError('Shared PDF unavailable');
    }
    if (_isLoadingPresentationPdf ||
        _presentationPdfUrl != url ||
        _presentationPdfPath == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return PDFView(
      key: ValueKey(_presentationPdfPath),
      filePath: _presentationPdfPath,
      defaultPage: page - 1,
      enableSwipe: false,
      swipeHorizontal: true,
      autoSpacing: false,
      pageFling: false,
      onViewCreated: (controller) {
        _presentationPdfController = controller;
        controller.setPage(page - 1);
      },
    );
  }

  void _retryPresentationPdf(String url, int page) {
    if (kIsWeb) {
      disposeWebPdfDocument(url);
    }
    _pdfDownloadGeneration++;
    setState(() {
      _webPdfReloadNonce++;
      _presentationPdfBytes = null;
      _presentationPdfLoadError = null;
      _isLoadingPresentationPdf = false;
    });
    unawaited(
      _preparePresentationPdf(<String, dynamic>{'url': url, 'page': page}),
    );
  }

  Widget _buildPresentationError(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.description_rounded,
            color: Colors.white54,
            size: 56,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _bufferingTimer?.cancel();
    _chewieController?.dispose();
    _videoPlayerController?.removeListener(_handlePlaybackProgress);
    unawaited(_videoPlayerController?.dispose());
    // Clean up temp file (only used for Base64 fallback)
    if (_tempFilePath != null) {
      try {
        File(_tempFilePath!).deleteSync();
      } catch (_) {}
    }
    if (_presentationPdfPath != null) {
      try {
        File(_presentationPdfPath!).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.title,
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator(color: Colors.white)
            : _errorMessage != null
            ? _buildPlayerError()
            : _buildPlayer(),
      ),
    );
  }

  Widget _buildPlayerError() {
    final hasUrl = widget.videoUrl?.isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.videocam_off_rounded,
            color: Colors.white38,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton.icon(
                onPressed: _retryPlayback,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
              if (hasUrl && !kIsWeb)
                OutlinedButton.icon(
                  onPressed: _openCompatibilityPlayer,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.smart_display_outlined),
                  label: const Text('Compatibility player'),
                ),
              if (hasUrl)
                OutlinedButton.icon(
                  onPressed: _openInBrowser,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Open in browser'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
