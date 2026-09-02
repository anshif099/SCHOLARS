import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Plays a WebM (or any URL) video inside an embedded WebView.
///
/// On Android, the system WebView is Chromium-based and supports VP8/VP9 WebM
/// natively, solving the incompatibility with Flutter's [video_player] package.
///
/// On iOS, WebM support depends on the OS, codec, and file indexing. Older
/// browser recordings should be converted to H.264/AAC MP4 for reliable use.
class WebmVideoPlayerPage extends StatefulWidget {
  final String videoUrl;
  final String title;
  final List<Map<String, dynamic>> presentationEvents;

  const WebmVideoPlayerPage({
    super.key,
    required this.videoUrl,
    required this.title,
    this.presentationEvents = const <Map<String, dynamic>>[],
  });

  @override
  State<WebmVideoPlayerPage> createState() => _WebmVideoPlayerPageState();
}

class _WebmVideoPlayerPageState extends State<WebmVideoPlayerPage> {
  static const Duration _videoLoadTimeout = Duration(seconds: 30);

  WebViewController? _controller;
  bool _isLoading = true;
  bool _isIOS = false;
  bool _videoWasReady = false;
  String? _errorMessage;
  Timer? _loadTimer;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      // iOS (WKWebView) cannot decode VP8/VP9 — skip WebView setup there
      _isIOS = defaultTargetPlatform == TargetPlatform.iOS;
      if (!_isIOS) {
        _initWebView();
      } else {
        setState(() => _isLoading = false);
      }
    }
  }

  void _initWebView() {
    _loadTimer?.cancel();
    _videoWasReady = false;
    _errorMessage = null;

    final htmlContent = _buildHtmlPlayer(
      widget.videoUrl,
      widget.presentationEvents,
    );
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'VideoPlayerStatus',
        onMessageReceived: _handleVideoStatus,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
            if (error.isForMainFrame == true) {
              _showPlaybackError(
                'The video page could not be opened. Check the internet connection and try again.',
              );
            }
          },
        ),
      )
      ..loadHtmlString(htmlContent, baseUrl: null);

    if (mounted) {
      setState(() {
        _controller = controller;
        _isLoading = true;
      });
    }
    _armLoadTimeout();
  }

  void _handleVideoStatus(JavaScriptMessage message) {
    if (!mounted) return;

    try {
      final payload = jsonDecode(message.message);
      if (payload is! Map) return;
      final status = payload['status']?.toString();
      final details = payload['details']?.toString();

      switch (status) {
        case 'ready':
        case 'playing':
          _loadTimer?.cancel();
          _loadTimer = null;
          _videoWasReady = true;
          if (_isLoading || _errorMessage != null) {
            setState(() {
              _isLoading = false;
              _errorMessage = null;
            });
          }
          break;
        case 'waiting':
        case 'stalled':
          _armLoadTimeout(buffering: _videoWasReady);
          break;
        case 'error':
          debugPrint('HTML video playback error: $details');
          _showPlaybackError(_playbackErrorMessage(details));
          break;
      }
    } catch (error) {
      debugPrint('Invalid video status message: $error');
    }
  }

  String _playbackErrorMessage(String? details) {
    if (details?.contains('code 2') == true) {
      return 'The video could not be downloaded on this network. Try Wi-Fi or mobile data, then try again.';
    }
    if (details?.contains('code 3') == true) {
      return 'This device could not decode the recording. Try opening it in your browser.';
    }
    if (details?.contains('code 4') == true) {
      return 'This video format is not supported on this device. Try opening it in your browser.';
    }
    return 'This recording could not be played on this device or network.';
  }

  void _armLoadTimeout({bool buffering = false}) {
    if (_loadTimer?.isActive == true) return;
    _loadTimer = Timer(_videoLoadTimeout, () {
      if (!mounted) return;
      _showPlaybackError(
        buffering
            ? 'The video stopped buffering. Try again or open it in your browser.'
            : 'The video server is taking too long to respond. Try another network or open it in your browser.',
      );
    });
  }

  void _showPlaybackError(String message) {
    _loadTimer?.cancel();
    _loadTimer = null;
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _errorMessage = message;
    });
  }

  void _retryPlayback() {
    if (!mounted) return;
    setState(() {
      _controller = null;
      _isLoading = true;
      _errorMessage = null;
    });
    _initWebView();
  }

  String _buildHtmlPlayer(
    String videoUrl,
    List<Map<String, dynamic>> presentationEvents,
  ) {
    final safeUrl = videoUrl
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final eventsJson = jsonEncode(presentationEvents).replaceAll('</', r'<\/');
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <title>Video Player</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body {
      width: 100%; height: 100%;
      background: #000;
      display: flex;
      align-items: center;
      justify-content: center;
      overflow: hidden;
    }
    video {
      width: 100%;
      height: 100%;
      object-fit: contain;
      background: #000;
    }
    #presentation {
      display: none;
      position: absolute;
      z-index: 2;
      inset: 0 0 58px 0;
      background: #111318;
      pointer-events: none;
    }
    #presentationHeader {
      height: 44px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 0 16px;
      color: white;
      background: rgba(18, 22, 30, 0.96);
      font: 600 13px Arial, sans-serif;
    }
    #presentationName {
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    #presentationPage { color: rgba(255,255,255,.72); flex: none; }
    #presentationBody {
      position: relative;
      width: 100%;
      height: calc(100% - 44px);
      overflow: hidden;
      background: white;
    }
    #presentationContent {
      position: absolute;
      inset: 0;
      transform-origin: 0 0;
    }
    #presentationImage, #presentationPdf {
      width: 100%;
      height: 100%;
      border: 0;
      object-fit: contain;
      background: white;
    }
    #drawingCanvas {
      position: absolute;
      z-index: 3;
      inset: 0;
      width: 100%;
      height: 100%;
      pointer-events: none;
    }
  </style>
</head>
<body>
  <video
    id="vid"
    controls
    autoplay
    playsinline
    preload="auto"
    src="$safeUrl">
    Your browser does not support HTML5 video.
  </video>
  <div id="presentation">
    <div id="presentationHeader">
      <span id="presentationName">Shared note</span>
      <span id="presentationPage"></span>
    </div>
    <div id="presentationBody">
      <div id="presentationContent">
        <img id="presentationImage" alt="Shared class note">
        <iframe id="presentationPdf"></iframe>
      </div>
      <canvas id="drawingCanvas"></canvas>
    </div>
  </div>
  <script>
    var v = document.getElementById('vid');
    var events = $eventsJson;
    var activeEventIndex = -2;
    var presentation = document.getElementById('presentation');
    var presentationName = document.getElementById('presentationName');
    var presentationPage = document.getElementById('presentationPage');
    var presentationBody = document.getElementById('presentationBody');
    var presentationContent = document.getElementById('presentationContent');
    var presentationImage = document.getElementById('presentationImage');
    var presentationPdf = document.getElementById('presentationPdf');
    var drawingCanvas = document.getElementById('drawingCanvas');
    var activePresentationState = null;
    var loadedResourceKey = '';

    function eventMatchesPresentation(event, state) {
      if (!state) return false;
      if (event.url && event.url !== state.url) return false;
      if (event.page && Number(event.page) !== Number(state.page)) return false;
      return true;
    }

    function resolvePresentation(positionMs) {
      var state = null;
      var index = -1;
      for (var i = 0; i < events.length; i++) {
        var event = events[i];
        if ((event.offset_ms || 0) > positionMs) break;
        index = i;
        if (event.action === 'show') {
          state = Object.assign({}, event);
          state.strokes = Array.isArray(event.strokes)
              ? event.strokes.slice() : [];
        } else if (event.action === 'hide') {
          state = null;
        } else if (event.action === 'stroke' &&
                   event.stroke && eventMatchesPresentation(event, state)) {
          state.strokes = (state.strokes || []).concat([event.stroke]);
        } else if (event.action === 'clear' &&
                   eventMatchesPresentation(event, state)) {
          state.strokes = [];
        } else if (event.action === 'view' &&
                   eventMatchesPresentation(event, state)) {
          state.zoom = event.zoom;
          state.pan_x = event.pan_x;
          state.pan_y = event.pan_y;
        }
      }
      return { index: index, state: state };
    }

    function boundedNumber(value, minimum, maximum, fallback) {
      var number = Number(value);
      if (!Number.isFinite(number)) return fallback;
      return Math.max(minimum, Math.min(maximum, number));
    }

    function drawStrokes(state) {
      var width = presentationBody.clientWidth;
      var height = presentationBody.clientHeight;
      var ratio = Math.max(1, window.devicePixelRatio || 1);
      drawingCanvas.width = Math.max(1, Math.round(width * ratio));
      drawingCanvas.height = Math.max(1, Math.round(height * ratio));
      var context = drawingCanvas.getContext('2d');
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      context.clearRect(0, 0, width, height);

      var strokes = state && Array.isArray(state.strokes)
          ? state.strokes : [];
      strokes.forEach(function(stroke) {
        var points = stroke && Array.isArray(stroke.points)
            ? stroke.points : [];
        if (!points.length) return;

        var argb = Number(stroke.color || 4294901760) >>> 0;
        var alpha = ((argb >>> 24) & 255) / 255;
        var red = (argb >>> 16) & 255;
        var green = (argb >>> 8) & 255;
        var blue = argb & 255;
        context.strokeStyle = 'rgba(' + red + ',' + green + ',' + blue + ',' + alpha + ')';
        context.lineWidth = boundedNumber(stroke.stroke_width, 1, 24, 3);
        context.lineCap = 'round';
        context.lineJoin = 'round';
        context.beginPath();
        var firstX = boundedNumber(points[0].x, 0, 1, 0) * width;
        var firstY = boundedNumber(points[0].y, 0, 1, 0) * height;
        context.moveTo(firstX, firstY);
        if (points.length === 1) {
          context.lineTo(firstX + 0.01, firstY);
        } else {
          for (var pointIndex = 1; pointIndex < points.length; pointIndex++) {
            context.lineTo(
              boundedNumber(points[pointIndex].x, 0, 1, 0) * width,
              boundedNumber(points[pointIndex].y, 0, 1, 0) * height
            );
          }
        }
        context.stroke();
      });
    }

    function renderPresentation(state) {
      activePresentationState = state;
      if (!state) {
        presentation.style.display = 'none';
        presentationImage.removeAttribute('src');
        presentationPdf.removeAttribute('src');
        loadedResourceKey = '';
        drawStrokes(null);
        return;
      }

      presentation.style.display = 'block';
      presentationName.textContent = state.file_name || 'Shared note';
      var page = Math.max(1, Number(state.page || 1));
      var resourceKey = (state.file_type || 'image') + '|' + state.url + '|' + page;
      if (state.file_type === 'pdf') {
        presentationPage.textContent = 'Page ' + page;
        presentationImage.style.display = 'none';
        presentationPdf.style.display = 'block';
        if (loadedResourceKey !== resourceKey) {
          presentationPdf.src = 'https://docs.google.com/gview?embedded=1&url=' +
              encodeURIComponent(state.url + '#page=' + page);
        }
      } else {
        presentationPage.textContent = '';
        presentationPdf.style.display = 'none';
        presentationImage.style.display = 'block';
        if (loadedResourceKey !== resourceKey) {
          presentationImage.src = state.url;
        }
      }
      loadedResourceKey = resourceKey;

      var zoom = boundedNumber(state.zoom, 1, 5, 1);
      var panX = boundedNumber(state.pan_x, -5, 5, 0) * presentationBody.clientWidth;
      var panY = boundedNumber(state.pan_y, -5, 5, 0) * presentationBody.clientHeight;
      presentationContent.style.transform = 'matrix(' + zoom + ',0,0,' + zoom + ',' + panX + ',' + panY + ')';
      drawStrokes(state);
    }

    function syncPresentation() {
      var positionMs = Math.floor((v.currentTime || 0) * 1000);
      var resolved = resolvePresentation(positionMs);
      if (resolved.index === activeEventIndex) return;
      activeEventIndex = resolved.index;
      renderPresentation(resolved.state);
    }

    function reportStatus(status, details) {
      if (window.VideoPlayerStatus) {
        VideoPlayerStatus.postMessage(JSON.stringify({
          status: status,
          details: details || ''
        }));
      }
    }

    v.addEventListener('loadedmetadata', function() {
      reportStatus('ready');
      syncPresentation();
      v.play().catch(function() {
        // Autoplay may be blocked — user can tap play manually
      });
    });
    v.addEventListener('canplay', function() { reportStatus('ready'); });
    v.addEventListener('playing', function() { reportStatus('playing'); });
    v.addEventListener('waiting', function() { reportStatus('waiting'); });
    v.addEventListener('stalled', function() { reportStatus('stalled'); });
    v.addEventListener('error', function() {
      var mediaError = v.error;
      reportStatus(
        'error',
        mediaError ? 'MediaError code ' + mediaError.code : 'Unknown media error'
      );
    });
    v.addEventListener('timeupdate', syncPresentation);
    v.addEventListener('seeking', syncPresentation);
    window.addEventListener('resize', function() {
      renderPresentation(activePresentationState);
    });
  </script>
</body>
</html>
''';
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.parse(widget.videoUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open browser. Please copy the link and open it manually.',
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
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
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // iOS: offer a last-resort browser attempt while clearly explaining that
    // the reliable fix is server-side MP4 conversion.
    if (_isIOS) {
      return _buildIOSFallback();
    }

    if (_controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_errorMessage != null) {
      return _buildPlaybackError();
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        if (_isLoading)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      ],
    );
  }

  Widget _buildPlaybackError() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.video_file_outlined,
            color: Colors.white54,
            size: 64,
          ),
          const SizedBox(height: 18),
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
              OutlinedButton.icon(
                onPressed: _openInBrowser,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                icon: const Icon(Icons.open_in_browser_rounded),
                label: const Text('Open in browser'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// WebM support varies by iOS version, so offer the system browser.
  Widget _buildIOSFallback() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.open_in_browser_rounded,
              color: Colors.white54,
              size: 44,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'MP4 Conversion Needed',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'This older recording is in WebM format. iPhone may load only its sound or remain buffering until it is converted to MP4.\n\nYou can still try the system browser below.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: Colors.white60,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_browser_rounded),
            label: Text(
              'Open in Browser',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
