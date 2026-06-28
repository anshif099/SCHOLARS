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
/// On iOS, WKWebView does NOT support VP8/VP9 WebM, so we fall back to showing
/// an "Open in Browser" prompt (Chrome/Firefox on iOS can play WebM).
class WebmVideoPlayerPage extends StatefulWidget {
  final String videoUrl;
  final String title;

  const WebmVideoPlayerPage({
    super.key,
    required this.videoUrl,
    required this.title,
  });

  @override
  State<WebmVideoPlayerPage> createState() => _WebmVideoPlayerPageState();
}

class _WebmVideoPlayerPageState extends State<WebmVideoPlayerPage> {
  WebViewController? _controller;
  bool _isLoading = true;
  bool _isIOS = false;

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
    final htmlContent = _buildHtmlPlayer(widget.videoUrl);
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
            if (mounted) setState(() => _isLoading = false);
          },
        ),
      )
      ..loadHtmlString(htmlContent, baseUrl: null);

    setState(() {
      _controller = controller;
    });
  }

  String _buildHtmlPlayer(String videoUrl) {
    // Escape double-quotes in URL to safely embed in HTML attribute
    final safeUrl = videoUrl.replaceAll('"', '&quot;');
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
  <script>
    var v = document.getElementById('vid');
    v.addEventListener('loadedmetadata', function() {
      v.play().catch(function() {
        // Autoplay may be blocked — user can tap play manually
      });
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
                'Could not open browser. Please copy the link and open it manually.'),
          ),
        );
      }
    }
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
    // iOS: WKWebView doesn't support VP8/VP9 — show open-in-browser prompt
    if (_isIOS) {
      return _buildIOSFallback();
    }

    if (_controller == null) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        if (_isLoading)
          const Center(
              child: CircularProgressIndicator(color: Colors.white)),
      ],
    );
  }

  /// iOS cannot play WebM in WKWebView — prompt user to open in a browser.
  /// Chrome/Firefox on iOS DO support WebM.
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
            child: const Icon(Icons.open_in_browser_rounded,
                color: Colors.white54, size: 44),
          ),
          const SizedBox(height: 24),
          Text(
            'Open in Browser',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'This recording is in WebM format. Safari cannot play WebM, but Chrome or Firefox can.\n\nTap below to open in your browser.',
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
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
