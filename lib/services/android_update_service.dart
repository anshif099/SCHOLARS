import 'package:in_app_update/in_app_update.dart';
import 'package:url_launcher/url_launcher.dart';

class AndroidUpdateCheckResult {
  final bool updateRequired;
  final int? availableVersionCode;

  const AndroidUpdateCheckResult({
    required this.updateRequired,
    this.availableVersionCode,
  });
}

class AndroidUpdateService {
  const AndroidUpdateService._();

  static const String packageName = 'com.academy.scholars';
  static final Uri _playStoreAppUri = Uri.parse(
    'market://details?id=$packageName',
  );
  static final Uri _playStoreWebUri = Uri.parse(
    'https://play.google.com/store/apps/details?id=$packageName',
  );

  static Future<AndroidUpdateCheckResult> checkForUpdate() async {
    final updateInfo = await InAppUpdate.checkForUpdate();
    final availability = updateInfo.updateAvailability;

    if (availability == UpdateAvailability.unknown) {
      throw StateError('Google Play returned an unknown update status.');
    }

    return AndroidUpdateCheckResult(
      updateRequired:
          availability == UpdateAvailability.updateAvailable ||
          availability == UpdateAvailability.developerTriggeredUpdateInProgress,
      availableVersionCode: updateInfo.availableVersionCode,
    );
  }

  static Future<bool> openPlayStore() async {
    try {
      if (await launchUrl(
        _playStoreAppUri,
        mode: LaunchMode.externalApplication,
      )) {
        return true;
      }
    } catch (_) {
      // Fall back to the HTTPS listing when the Play Store app is unavailable.
    }

    try {
      return await launchUrl(
        _playStoreWebUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}
