import 'dart:convert';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../services/video_web_helper.dart';
import '../theme/app_theme.dart';

class VideoPlayerPage extends StatefulWidget {
  /// Firebase Storage download URL (preferred).
  final String? videoUrl;

  /// Legacy Base64-encoded video data (fallback for old recordings).
  final String? videoBase64;

  final String title;

  const VideoPlayerPage({
    super.key,
    this.videoUrl,
    this.videoBase64,
    required this.title,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  bool _isLoading = true;
  String? _errorMessage;
  String? _tempFilePath;

  @override
  void initState() {
    super.initState();
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

  Future<void> _initFromUrl(String url) async {
    try {
      _videoPlayerController = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      // Wait for initialization with an 8-second timeout
      await _videoPlayerController!.initialize().timeout(const Duration(seconds: 8));
      await _videoPlayerController!.setLooping(false);
      await _videoPlayerController!.setPlaybackSpeed(1);
      _createChewieController();

      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (e) {
      // Fallback: If on Web, try fetching the video as a local Blob URL
      if (kIsWeb) {
        try {
          final blobUrl = await VideoWebHelper().fetchBlobUrl(url);
          _videoPlayerController = VideoPlayerController.networkUrl(
            Uri.parse(blobUrl),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
          );
          // Wait for initialization of Blob URL with a 5-second timeout
          await _videoPlayerController!.initialize().timeout(const Duration(seconds: 5));
          await _videoPlayerController!.setLooping(false);
          await _videoPlayerController!.setPlaybackSpeed(1);
          _createChewieController();

          if (!mounted) return;
          setState(() => _isLoading = false);
          return;
        } catch (blobError) {
          debugPrint('Blob URL fallback failed: $blobError');
        }
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'This video format (VP8/WebM) is not supported by Safari on iPhone. Please play this video on Android or PC, or record future classes using a compatible browser.';
      });
    }
  }

  Future<void> _initFromBase64(String base64Data) async {
    try {
      // Decode Base64 to bytes and write to a temp file
      final bytes = base64Decode(base64Data);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/playback_${DateTime.now().millisecondsSinceEpoch}.mp4');
      await tempFile.writeAsBytes(bytes);
      _tempFilePath = tempFile.path;

      _videoPlayerController = VideoPlayerController.file(tempFile);
      await _prepareVideoController();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load video: $e';
      });
    }
  }

  Future<void> _prepareVideoController() async {
    await _videoPlayerController!.initialize();
    await _videoPlayerController!.setLooping(false);
    await _videoPlayerController!.setPlaybackSpeed(1);
    _createChewieController();

    if (!mounted) return;
    setState(() => _isLoading = false);
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
            child: CircularProgressIndicator(color: Colors.white)),
      ),
      bufferingBuilder: (context) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
      errorBuilder: (context, errorMessage) {
        return Center(
          child: Text(
            errorMessage,
            style: const TextStyle(color: Colors.white),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _videoPlayerController?.dispose();
    _chewieController?.dispose();
    // Clean up temp file (only used for Base64 fallback)
    if (_tempFilePath != null) {
      try {
        File(_tempFilePath!).deleteSync();
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
              fontWeight: FontWeight.w600),
        ),
      ),
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator(color: Colors.white)
            : _errorMessage != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.videocam_off_rounded,
                            color: Colors.white38, size: 64),
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                              color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  )
                : (_chewieController != null &&
                        _chewieController!
                            .videoPlayerController.value.isInitialized)
                    ? Chewie(controller: _chewieController!)
                    : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}
