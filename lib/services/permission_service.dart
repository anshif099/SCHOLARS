import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> requestCameraAndMic() async {
    if (kIsWeb) return true;
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    return statuses[Permission.camera] == PermissionStatus.granted &&
           statuses[Permission.microphone] == PermissionStatus.granted;
  }

  static Future<void> requestAllPermissions() async {
    if (kIsWeb) return;
    await [
      Permission.camera,
      Permission.microphone,
      Permission.notification,
    ].request();
  }
}

