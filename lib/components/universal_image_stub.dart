import 'package:flutter/material.dart';

Widget buildPlatformImage({
  required String imageUrl,
  double? width,
  double? height,
  required BoxFit fit,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  return Image.network(
    imageUrl,
    width: width,
    height: height,
    fit: fit,
    errorBuilder: errorBuilder,
  );
}
