import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceSessionService {
  static const String _prefKeyDeviceId = 'local_device_id';
  static String? _cachedDeviceId;

  /// Returns a persistent unique device ID for this device session.
  static Future<String> getDeviceId() async {
    if (_cachedDeviceId != null && _cachedDeviceId!.isNotEmpty) {
      return _cachedDeviceId!;
    }

    if (kIsWeb) {
      _cachedDeviceId = const Uuid().v4();
      return _cachedDeviceId!;
    }

    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_prefKeyDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await prefs.setString(_prefKeyDeviceId, deviceId);
    }
    _cachedDeviceId = deviceId;
    return deviceId;
  }

  /// Returns metadata describing this device and platform.
  static Future<Map<String, dynamic>> getDeviceDetails() async {
    final deviceId = await getDeviceId();
    String platformName = 'Unknown Platform';
    String deviceName = 'Unknown Device';

    if (kIsWeb) {
      platformName = 'Web';
      deviceName = 'Web Browser';
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          platformName = 'Android';
          deviceName = 'Android Mobile App';
          break;
        case TargetPlatform.iOS:
          platformName = 'iOS';
          deviceName = 'iPhone / iPad';
          break;
        case TargetPlatform.windows:
          platformName = 'Windows';
          deviceName = 'Windows PC';
          break;
        case TargetPlatform.macOS:
          platformName = 'macOS';
          deviceName = 'Mac';
          break;
        case TargetPlatform.linux:
          platformName = 'Linux';
          deviceName = 'Linux PC';
          break;
        default:
          platformName = 'Mobile/Desktop';
          deviceName = 'Other Device';
          break;
      }
    }

    final now = DateTime.now();
    final formattedTime = _formatTimestamp(now);

    return {
      'device_id': deviceId,
      'device_name': deviceName,
      'platform': platformName,
      'login_time': formattedTime,
      'timestamp': now.millisecondsSinceEpoch,
    };
  }

  /// Fetches the currently registered active device for the given student.
  static Future<Map<dynamic, dynamic>?> getActiveDeviceSession(
    String studentKey,
  ) async {
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref()
          .child('students')
          .child(studentKey)
          .child('active_device')
          .get()
          .timeout(const Duration(seconds: 10));

      if (snapshot.exists && snapshot.value is Map) {
        return Map<dynamic, dynamic>.from(snapshot.value as Map);
      }
    } catch (e) {
      debugPrint('Error getting active device session: $e');
    }
    return null;
  }

  /// Registers this device as the active session in Realtime Database.
  static Future<void> registerDeviceSession(String studentKey) async {
    try {
      final details = await getDeviceDetails();
      await FirebaseDatabase.instance
          .ref()
          .child('students')
          .child(studentKey)
          .child('active_device')
          .set(details)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Error registering device session: $e');
    }
  }

  /// Clears the active device session if it belongs to this device.
  static Future<void> clearDeviceSession(String studentKey) async {
    try {
      final localDeviceId = await getDeviceId();
      final activeSession = await getActiveDeviceSession(studentKey);
      if (activeSession != null &&
          activeSession['device_id'] == localDeviceId) {
        await FirebaseDatabase.instance
            .ref()
            .child('students')
            .child(studentKey)
            .child('active_device')
            .remove();
      }
    } catch (e) {
      debugPrint('Error clearing device session: $e');
    }
  }

  /// Listens to session changes in Firebase Realtime Database.
  /// If another device logs in, [onSessionRevoked] is called with the new device name.
  static StreamSubscription<DatabaseEvent>? listenToActiveSession({
    required String studentKey,
    required Function(String newDeviceName) onSessionRevoked,
  }) {
    final ref = FirebaseDatabase.instance
        .ref()
        .child('students')
        .child(studentKey)
        .child('active_device');

    String? currentDeviceId;
    getDeviceId().then((id) => currentDeviceId = id);

    return ref.onValue.listen((event) async {
      final snapshot = event.snapshot;
      if (!snapshot.exists || snapshot.value is! Map) {
        return;
      }

      final activeSession = Map<dynamic, dynamic>.from(snapshot.value as Map);
      final activeDeviceId = activeSession['device_id']?.toString();
      currentDeviceId ??= await getDeviceId();

      if (activeDeviceId != null &&
          activeDeviceId.isNotEmpty &&
          activeDeviceId != currentDeviceId) {
        final newDeviceName =
            activeSession['device_name']?.toString() ?? 'Another Device';
        onSessionRevoked(newDeviceName);
      }
    });
  }

  static String _formatTimestamp(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = months[dt.month - 1];
    final day = dt.day.toString().padLeft(2, '0');
    final year = dt.year;
    final hour = dt.hour == 0
        ? 12
        : dt.hour > 12
            ? dt.hour - 12
            : dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';

    return '$day $month $year, $hour:$minute $period';
  }
}
