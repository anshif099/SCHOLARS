bool shouldUseMobileWebPdfRenderer({
  required String userAgent,
  required String platform,
  required int maxTouchPoints,
}) {
  final isIos = RegExp(
    r'iPad|iPhone|iPod',
    caseSensitive: false,
  ).hasMatch(userAgent);
  final isDesktopModeIpad = platform == 'MacIntel' && maxTouchPoints > 1;
  final isAndroid = RegExp(
    r'Android',
    caseSensitive: false,
  ).hasMatch(userAgent);
  return isIos || isDesktopModeIpad || isAndroid;
}
