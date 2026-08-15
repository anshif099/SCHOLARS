import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as web_ui;

import 'package:flutter/foundation.dart';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

// An error code value to error name Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorName = {
  1: 'MEDIA_ERR_ABORTED',
  2: 'MEDIA_ERR_NETWORK',
  3: 'MEDIA_ERR_DECODE',
  4: 'MEDIA_ERR_SRC_NOT_SUPPORTED',
};

// An error code value to description Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorDescription = {
  1: 'The user canceled the fetching of the video.',
  2: 'A network error occurred while fetching the video, despite having previously been available.',
  3: 'An error occurred while trying to decode the video, despite having previously been determined to be usable.',
  4: 'The video has been found to be unsuitable (missing or in a format not supported by your browser).',
};

// The default error message, when the error is an empty string
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/message
const String _kDefaultErrorMessage =
    'No further diagnostic information can be determined or provided.';

class RTCVideoRenderer extends ValueNotifier<RTCVideoValue>
    implements VideoRenderer {
  RTCVideoRenderer()
      : _textureId = _textureCounter++,
        super(RTCVideoValue.empty);

  static const _elementIdForAudioManager = 'html_webrtc_audio_manager_list';

  web.HTMLAudioElement? _audioElement;

  static int _textureCounter = 1;

  web.MediaStream? _videoStream;

  web.MediaStream? _audioStream;

  MediaStreamWeb? _srcObject;

  final int _textureId;

  bool mirror = false;

  final _subscriptions = <StreamSubscription>[];

  final _audioSubscriptions = <StreamSubscription>[];

  Timer? _audioRetryTimer;

  bool _audioPlayInProgress = false;

  String _objectFit = 'contain';

  bool _muted = false;

  set objectFit(String fit) {
    if (_objectFit == fit) return;
    _objectFit = fit;
    findHtmlView()?.style.objectFit = fit;
  }

  @override
  int get videoWidth => value.width.toInt();

  @override
  int get videoHeight => value.height.toInt();

  @override
  int get textureId => _textureId;

  @override
  bool get muted => _muted;

  @override
  set muted(bool mute) {
    _muted = mute;
    _audioElement?.muted = mute;
    if (!mute) {
      unawaited(_tryPlayAudio());
    }
  }

  double _volume = 1.0;

  double get volume => _volume;

  set volume(double val) {
    _volume = val;
    _audioElement?.volume = val;
    if (val > 0 && !_muted) {
      unawaited(_tryPlayAudio());
    }
  }

  Future<void> _tryPlayVideo(web.HTMLVideoElement element) async {
    try {
      element.muted = true;
      element.setAttribute('playsinline', 'true');
      element.setAttribute('webkit-playsinline', 'true');
      element.playsInline = true;
      await element.play().toDart;
    } catch (_) {
      // Autoplay on Safari iOS requires element to be in DOM; retry after micro-delays.
      for (final ms in [50, 150, 300, 600, 1000]) {
        await Future.delayed(Duration(milliseconds: ms));
        if (element.paused && element.srcObject != null) {
          try {
            await element.play().toDart;
            break;
          } catch (_) {}
        }
      }
    }
  }

  void ensureVideoPlaying() {
    final videoElement = findHtmlView();
    if (videoElement != null) {
      unawaited(_tryPlayVideo(videoElement));
    }
  }

  Future<bool> _tryPlayAudio() async {
    final element = _audioElement;
    if (element == null || element.muted || element.volume <= 0) {
      return false;
    }
    if (_audioPlayInProgress) {
      return !element.paused;
    }

    _audioPlayInProgress = true;
    try {
      // Browsers may reject this until it runs from a user gesture. The app's
      // "Enable class sound" action writes muted/volume again, which retries
      // play inside that gesture.
      await element.play().toDart;
      return !element.paused;
    } catch (_) {
      // Autoplay rejection is expected on some browsers. Keep the renderer
      // alive so playback can be retried after the user taps the sound action.
      return false;
    } finally {
      _audioPlayInProgress = false;
    }
  }

  void _scheduleAudioPlaybackRetry([
    Duration delay = const Duration(milliseconds: 250),
  ]) {
    _audioRetryTimer?.cancel();
    _audioRetryTimer = Timer(delay, () {
      unawaited(_tryPlayAudio());
    });
  }

  void _installAudioRecoveryListeners(web.HTMLAudioElement element) {
    for (final subscription in _audioSubscriptions) {
      unawaited(subscription.cancel());
    }
    _audioSubscriptions.clear();

    void retryNow(dynamic _) {
      unawaited(_tryPlayAudio());
    }

    void retrySoon(dynamic _) {
      if (!element.muted && element.srcObject != null) {
        _scheduleAudioPlaybackRetry();
      }
    }

    _audioSubscriptions.add(element.onCanPlay.listen(retryNow));
    _audioSubscriptions.add(element.onPause.listen(retrySoon));
    _audioSubscriptions.add(element.onStalled.listen(retrySoon));
    _audioSubscriptions.add(element.onWaiting.listen(retrySoon));
    _audioSubscriptions.add(
      web.document.onVisibilityChange.listen((_) {
        if (web.document.visibilityState == 'visible') {
          retryNow(null);
        }
      }),
    );

    // A genuine user gesture is required after an autoplay rejection. Listen
    // at the document body as well as in Flutter so taps on platform views,
    // touches, and keyboard interaction all recover remote audio playback.
    final body = web.document.body;
    if (body != null) {
      _audioSubscriptions.add(body.onMouseDown.listen(retryNow));
      _audioSubscriptions.add(body.onTouchStart.listen(retryNow));
      _audioSubscriptions.add(body.onKeyDown.listen(retryNow));
    }
  }

  @override
  bool get renderVideo => _srcObject != null;

  String get _elementIdForAudio => 'audio_$viewType';

  String get _elementIdForVideo => 'video_$viewType';

  String get viewType => 'RTCVideoRenderer-$textureId';

  void _updateAllValues(web.HTMLVideoElement fallback) {
    final element = findHtmlView() ?? fallback;
    value = value.copyWith(
      rotation: 0,
      width: element.videoWidth.toDouble(),
      height: element.videoHeight.toDouble(),
      renderVideo: renderVideo,
    );
  }

  @override
  MediaStream? get srcObject => _srcObject;

  @override
  set srcObject(MediaStream? stream) {
    if (stream == null) {
      findHtmlView()?.srcObject = null;
      _audioElement?.srcObject = null;
      _srcObject = null;
      return;
    }

    _srcObject = stream as MediaStreamWeb;

    if (null != _srcObject) {
      if (stream.getVideoTracks().isNotEmpty) {
        _videoStream = web.MediaStream();
        for (final track in _srcObject!.jsStream.getVideoTracks().toDart) {
          _videoStream!.addTrack(track);
        }
      }
      if (stream.getAudioTracks().isNotEmpty) {
        _audioStream = web.MediaStream();
        for (final track in _srcObject!.jsStream.getAudioTracks().toDart) {
          _audioStream!.addTrack(track);
        }
      }
    } else {
      _videoStream = null;
      _audioStream = null;
    }

    if (null != _audioStream) {
      if (null == _audioElement) {
        _audioElement = web.HTMLAudioElement()
          ..id = _elementIdForAudio
          ..muted = stream.ownerTag == 'local' || _muted
          ..volume = _volume
          ..autoplay = true;
        _ensureAudioManagerDiv().append(_audioElement!);
        _installAudioRecoveryListeners(_audioElement!);
      }
      _audioElement?.srcObject = _audioStream;
      unawaited(_tryPlayAudio());
    }

    var videoElement = findHtmlView();
    if (null != videoElement) {
      videoElement.srcObject = _videoStream;
      _applyDefaultVideoStyles(findHtmlView()!);
      unawaited(_tryPlayVideo(videoElement));
    }

    value = value.copyWith(renderVideo: renderVideo);
  }

  Future<void> setSrcObject({MediaStream? stream, String? trackId}) async {
    if (stream == null) {
      findHtmlView()?.srcObject = null;
      _audioElement?.srcObject = null;
      _srcObject = null;
      return;
    }

    _srcObject = stream as MediaStreamWeb;

    if (null != _srcObject) {
      if (stream.getVideoTracks().isNotEmpty) {
        _videoStream = web.MediaStream();
        for (final track in _srcObject!.jsStream.getVideoTracks().toDart) {
          if (track.id == trackId) {
            _videoStream!.addTrack(track);
          }
        }
      }
      if (stream.getAudioTracks().isNotEmpty) {
        _audioStream = web.MediaStream();
        for (final track in _srcObject!.jsStream.getAudioTracks().toDart) {
          _audioStream!.addTrack(track);
        }
      }
    } else {
      _videoStream = null;
      _audioStream = null;
    }

    if (null != _audioStream) {
      if (null == _audioElement) {
        _audioElement = web.HTMLAudioElement()
          ..id = _elementIdForAudio
          ..muted = stream.ownerTag == 'local' || _muted
          ..volume = _volume
          ..autoplay = true;
        _ensureAudioManagerDiv().append(_audioElement!);
        _installAudioRecoveryListeners(_audioElement!);
      }
      _audioElement?.srcObject = _audioStream;
      unawaited(_tryPlayAudio());
    }

    var videoElement = findHtmlView();
    if (null != videoElement) {
      videoElement.srcObject = _videoStream;
      _applyDefaultVideoStyles(findHtmlView()!);
      unawaited(_tryPlayVideo(videoElement));
    }

    value = value.copyWith(renderVideo: renderVideo);
  }

  web.HTMLDivElement _ensureAudioManagerDiv() {
    var div = web.document.getElementById(_elementIdForAudioManager);
    if (null != div) return div as web.HTMLDivElement;

    div = web.HTMLDivElement()
      ..id = _elementIdForAudioManager
      ..style.display = 'none';
    web.document.body?.append(div);
    return div as web.HTMLDivElement;
  }

  web.HTMLVideoElement? findHtmlView() {
    final element = web.document.getElementById(_elementIdForVideo);
    if (null != element) return element as web.HTMLVideoElement;
    return null;
  }

  @override
  Future<void> dispose() async {
    _srcObject = null;
    _audioRetryTimer?.cancel();
    _audioRetryTimer = null;
    for (var subscription in _audioSubscriptions) {
      await subscription.cancel();
    }
    _audioSubscriptions.clear();
    for (var s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    final element = findHtmlView();
    element?.removeAttribute('src');
    element?.load();
    _audioElement?.remove();
    final audioManager = web.document.getElementById(_elementIdForAudioManager)
        as web.HTMLDivElement?;
    if (audioManager != null && !audioManager.hasChildNodes()) {
      audioManager.remove();
    }
    return super.dispose();
  }

  @override
  Future<bool> audioOutput(String deviceId) async {
    try {
      final element = _audioElement;
      if (null != element) {
        await element.setSinkId(deviceId).toDart;
        return true;
      }
    } catch (e) {
      print('Unable to setSinkId: ${e.toString()}');
    }
    return false;
  }

  @override
  Future<void> initialize() async {
    web_ui.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      for (var s in _subscriptions) {
        s.cancel();
      }
      _subscriptions.clear();

      final element = web.HTMLVideoElement()
        ..autoplay = true
        ..muted = true
        ..controls = false
        ..srcObject = _videoStream
        ..id = _elementIdForVideo
        ..setAttribute('playsinline', 'true')
        ..setAttribute('webkit-playsinline', 'true')
        ..playsInline = true;

      _applyDefaultVideoStyles(element);
      unawaited(_tryPlayVideo(element));

      _subscriptions.add(
        element.onCanPlay.listen((dynamic _) {
          _updateAllValues(element);
          unawaited(_tryPlayVideo(element));
        }),
      );

      _subscriptions.add(
        element.onResize.listen((dynamic _) {
          _updateAllValues(element);
          onResize?.call();
        }),
      );

      // The error event fires when some form of error occurs while attempting to load or perform the media.
      _subscriptions.add(
        element.onError.listen((web.Event _) {
          final error = element.error;
          final codeName = error != null
              ? (_kErrorValueToErrorName[error.code] ?? 'MEDIA_ERR_UNKNOWN')
              : 'MEDIA_ERR_UNKNOWN';
          final message = error != null && error.message != ''
              ? error.message
              : _kDefaultErrorMessage;
          print('RTCVideoRenderer: videoElement.onError, code=$codeName, message=$message');
        }),
      );

      _subscriptions.add(
        element.onEnded.listen((dynamic _) {
          // print('RTCVideoRenderer: videoElement.onEnded');
        }),
      );

      return element;
    });
  }

  void _applyDefaultVideoStyles(web.HTMLVideoElement element) {
    // Flip the video horizontally if is mirrored.
    if (mirror) {
      element.style.transform = 'scaleX(-1)';
    }

    element
      ..style.objectFit = _objectFit
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.position = 'absolute'
      ..style.top = '0'
      ..style.left = '0';
  }

  @override
  Function? onResize;

  @override
  Function? onFirstFrameRendered;
}
