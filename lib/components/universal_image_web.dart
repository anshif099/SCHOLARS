import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

Widget buildPlatformImage({
  required String imageUrl,
  double? width,
  double? height,
  required BoxFit fit,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  // Use a unique viewType based on image URL hash and the fit property
  final String viewType = 'img-${imageUrl.hashCode}-${fit.hashCode}';

  ui_web.platformViewRegistry.registerViewFactory(
    viewType,
    (int viewId) {
      final img = html.ImageElement()
        ..src = imageUrl
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';

      if (fit == BoxFit.cover) {
        img.style.objectFit = 'cover';
      } else if (fit == BoxFit.contain) {
        img.style.objectFit = 'contain';
      } else if (fit == BoxFit.fill) {
        img.style.objectFit = 'fill';
      } else if (fit == BoxFit.none) {
        img.style.objectFit = 'none';
      } else {
        img.style.objectFit = 'cover';
      }

      return img;
    },
  );

  return SizedBox(
    width: width,
    height: height,
    child: HtmlElementView(viewType: viewType),
  );
}
