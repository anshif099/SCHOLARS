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
  );
}
