import 'package:flutter/material.dart';

Widget buildPlatformImage({
  required String imageUrl,
  double? width,
  double? height,
  required BoxFit fit,
  ImageLoadingBuilder? loadingBuilder,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  return Image.network(
    imageUrl,
    width: width,
    height: height,
    fit: fit,
    loadingBuilder: loadingBuilder,
    errorBuilder: errorBuilder,
    // Firebase download URLs are cross-origin on web. Let Flutter use its
    // managed <img> renderer so the image remains composited correctly when
    // it replaces an RTCVideoView, without requiring a CORS byte fetch.
    webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
  );
}
