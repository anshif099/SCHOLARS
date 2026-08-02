import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'firebase_upload_auth_service.dart';

String _sessionTokenHash(String token) {
  if (token.isEmpty) return '';
  return sha256.convert(utf8.encode(token)).toString();
}

class StudentSessionException implements Exception {
  final String message;

  const StudentSessionException(this.message);

  @override
  String toString() => message;
}

class StudentActiveSession {
  final String authUid;
  final String sessionTokenHash;
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final String platform;
  final String appVersion;
  final int? loginAt;
  final int? lastActive;

  const StudentActiveSession({
    required this.authUid,
    required this.sessionTokenHash,
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.platform,
    required this.appVersion,
    required this.loginAt,
    required this.lastActive,
  });

  factory StudentActiveSession.fromValue(Object? value) {
    final data = value is Map
        ? Map<dynamic, dynamic>.from(value)
        : <dynamic, dynamic>{};

    int? asInt(Object? raw) {
      if (raw is int) return raw;
      return int.tryParse(raw?.toString() ?? '');
    }

    return StudentActiveSession(
      authUid: data['auth_uid']?.toString() ?? '',
      sessionTokenHash:
          data['session_token_hash']?.toString() ??
          _sessionTokenHash(data['session_token']?.toString() ?? ''),
      deviceId: data['device_id']?.toString() ?? '',
      deviceName: data['device_name']?.toString() ?? 'Unknown device',
      deviceType: data['device_type']?.toString() ?? 'Unknown',
      platform: data['platform']?.toString() ?? 'Unknown',
      appVersion: data['app_version']?.toString() ?? '',
      loginAt: asInt(data['login_at']),
      lastActive: asInt(data['last_active']),
    );
  }
}

class StudentSessionClaimResult {
  final bool claimed;
  final StudentActiveSession? activeSession;

  const StudentSessionClaimResult({required this.claimed, this.activeSession});
}

class StudentSessionService {
  StudentSessionService._();

  static const _deviceIdKey = 'student_device_id';
  static const _sessionStudentKey = 'student_session_student_key';
  static const _sessionTokenKey = 'student_session_token';
  static const _uuid = Uuid();

  static DatabaseReference _sessionRef(String studentKey) => FirebaseDatabase
      .instance
      .ref()
      .child('student_sessions')
      .child(studentKey);

  static Future<StudentSessionClaimResult> claim(String studentKey) async {
    final normalizedKey = studentKey.trim();
    if (normalizedKey.isEmpty) {
      throw const StudentSessionException('Student account is invalid.');
    }

    final uid = await FirebaseUploadAuthService.ensureSignedIn();
    if (uid == null || uid.isEmpty) {
      throw const StudentSessionException(
        'Secure login could not be started. Check your internet connection and try again.',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final deviceId = await _loadOrCreateDeviceId(prefs);
    final savedStudentKey = prefs.getString(_sessionStudentKey);
    final savedToken = prefs.getString(_sessionTokenKey);
    final sessionToken =
        savedStudentKey == normalizedKey &&
            savedToken != null &&
            savedToken.isNotEmpty
        ? savedToken
        : _uuid.v4();
    final device = await _loadDeviceDetails();
    final ref = _sessionRef(normalizedKey);

    // Prime the local cache so an abort is based on the server's latest lock.
    await ref.get().timeout(const Duration(seconds: 15));

    final now = DateTime.now().millisecondsSinceEpoch;
    final result = await ref
        .runTransaction((currentValue) {
          final rawCurrent = currentValue;
          final current = rawCurrent is Map
              ? Map<dynamic, dynamic>.from(rawCurrent)
              : null;
          final isOwnedByThisDevice =
              current != null &&
              current['auth_uid']?.toString() == uid &&
              current['device_id']?.toString() == deviceId;

          if (current != null && !isOwnedByThisDevice) {
            return Transaction.abort();
          }

          return Transaction.success(<String, Object>{
            'auth_uid': uid,
            'session_token_hash': _sessionTokenHash(sessionToken),
            'device_id': deviceId,
            'device_name': device.name,
            'device_type': device.type,
            'platform': device.platform,
            'app_version': device.appVersion,
            'login_at': current?['login_at'] ?? now,
            'last_active': now,
          });
        }, applyLocally: false)
        .timeout(const Duration(seconds: 20));

    if (!result.committed) {
      final latest = await ref.get().timeout(const Duration(seconds: 15));
      return StudentSessionClaimResult(
        claimed: false,
        activeSession: latest.exists
            ? StudentActiveSession.fromValue(latest.value)
            : null,
      );
    }

    await prefs.setString(_sessionStudentKey, normalizedKey);
    await prefs.setString(_sessionTokenKey, sessionToken);
    await prefs.setBool('is_student_logged_in', true);
    await prefs.setString('student_data', normalizedKey);

    return StudentSessionClaimResult(
      claimed: true,
      activeSession: StudentActiveSession.fromValue(result.snapshot.value),
    );
  }

  static Future<bool> validateCurrentSession(String studentKey) async {
    final identity = await _loadLocalIdentity(studentKey);
    if (identity == null) return false;

    final snapshot = await _sessionRef(
      studentKey,
    ).get().timeout(const Duration(seconds: 15));
    if (!snapshot.exists) return false;

    return _isOwned(StudentActiveSession.fromValue(snapshot.value), identity);
  }

  static Stream<bool> watchCurrentSession(String studentKey) async* {
    final identity = await _loadLocalIdentity(studentKey);
    if (identity == null) {
      yield false;
      return;
    }

    await for (final event in _sessionRef(studentKey).onValue) {
      if (!event.snapshot.exists) {
        yield false;
        continue;
      }

      yield _isOwned(
        StudentActiveSession.fromValue(event.snapshot.value),
        identity,
      );
    }
  }

  static Future<bool> touch(String studentKey) async {
    final identity = await _loadLocalIdentity(studentKey);
    if (identity == null) return false;

    final ref = _sessionRef(studentKey);
    await ref.get().timeout(const Duration(seconds: 15));
    final result = await ref
        .runTransaction((currentValue) {
          final session = StudentActiveSession.fromValue(currentValue);
          if (!_isOwned(session, identity)) {
            return Transaction.abort();
          }

          final current = Map<dynamic, dynamic>.from(currentValue! as Map);
          current.remove('session_token');
          current['session_token_hash'] = _sessionTokenHash(
            identity.sessionToken,
          );
          current['last_active'] = DateTime.now().millisecondsSinceEpoch;
          return Transaction.success(current);
        }, applyLocally: false)
        .timeout(const Duration(seconds: 15));

    return result.committed;
  }

  static Future<void> releaseCurrentSession() async {
    final prefs = await SharedPreferences.getInstance();
    final studentKey = prefs.getString(_sessionStudentKey);
    final sessionToken = prefs.getString(_sessionTokenKey);
    final deviceId = prefs.getString(_deviceIdKey);
    if (studentKey == null ||
        studentKey.isEmpty ||
        sessionToken == null ||
        sessionToken.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty) {
      throw const StudentSessionException(
        'This device is missing its secure logout details. Please contact support to reset the session.',
      );
    }

    Object? serverError;
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'releaseStudentSession',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 20)),
      );
      final response = await callable.call(<String, String>{
        'studentKey': studentKey,
        'sessionToken': sessionToken,
        'deviceId': deviceId,
      });
      final data = response.data;
      if (data is Map && data['released'] == true) {
        await clearLocalSession();
        return;
      }
      serverError = const StudentSessionException(
        'The server could not release this device session.',
      );
    } catch (error) {
      serverError = error;
      debugPrint('Server-backed student session release failed: $error');
    }

    // Keep direct release as a safe fallback during the Cloud Function rollout.
    final identity = await _loadLocalIdentity(studentKey);
    if (identity != null) {
      try {
        final ref = _sessionRef(studentKey);
        await ref.get().timeout(const Duration(seconds: 15));
        final result = await ref
            .runTransaction((currentValue) {
              if (currentValue == null) {
                return Transaction.success(null);
              }
              final session = StudentActiveSession.fromValue(currentValue);
              if (!_isOwned(session, identity)) {
                return Transaction.abort();
              }

              return Transaction.success(null);
            }, applyLocally: false)
            .timeout(const Duration(seconds: 15));
        if (result.committed || !result.snapshot.exists) {
          await clearLocalSession();
          return;
        }
      } catch (error) {
        debugPrint('Direct student session release failed: $error');
        serverError = error;
      }
    }

    throw StudentSessionException(
      'Could not release this device session. Check the internet connection and try again. (${serverError.runtimeType})',
    );
  }

  static Future<void> clearLocalSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('is_student_logged_in');
    await prefs.remove('student_data');
    await prefs.remove(_sessionStudentKey);
    await prefs.remove(_sessionTokenKey);
  }

  static bool _isOwned(
    StudentActiveSession session,
    _LocalSessionIdentity identity,
  ) {
    return session.authUid.isNotEmpty &&
        session.authUid == identity.authUid &&
        session.deviceId == identity.deviceId &&
        session.sessionTokenHash == _sessionTokenHash(identity.sessionToken);
  }

  static Future<_LocalSessionIdentity?> _loadLocalIdentity(
    String studentKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final savedStudentKey = prefs.getString(_sessionStudentKey);
    final sessionToken = prefs.getString(_sessionTokenKey);
    final deviceId = prefs.getString(_deviceIdKey);
    final auth = FirebaseAuth.instance;
    var user = auth.currentUser;
    if (user == null) {
      try {
        user = await auth
            .authStateChanges()
            .firstWhere((candidate) => candidate != null)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // No persisted Firebase identity is available on this device.
      }
    }
    final uid = user?.uid;

    if (savedStudentKey != studentKey ||
        sessionToken == null ||
        sessionToken.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty ||
        uid == null ||
        uid.isEmpty) {
      return null;
    }

    return _LocalSessionIdentity(
      authUid: uid,
      sessionToken: sessionToken,
      deviceId: deviceId,
    );
  }

  static Future<String> _loadOrCreateDeviceId(SharedPreferences prefs) async {
    final saved = prefs.getString(_deviceIdKey);
    if (saved != null && saved.isNotEmpty) return saved;

    final created = _uuid.v4();
    await prefs.setString(_deviceIdKey, created);
    return created;
  }

  static Future<_DeviceDetails> _loadDeviceDetails() async {
    final info = await DeviceInfoPlugin().deviceInfo;
    final data = info.data;
    final package = await PackageInfo.fromPlatform();
    final platform = _platformLabel();

    String firstValue(List<String> keys) {
      for (final key in keys) {
        final value = data[key]?.toString().trim() ?? '';
        if (value.isNotEmpty && value.toLowerCase() != 'unknown') {
          return value;
        }
      }
      return '';
    }

    final String name;
    if (kIsWeb) {
      final browser = firstValue(['browserName']);
      name = browser.isEmpty
          ? 'Web browser'
          : '${_titleCase(browser.split('.').last)} browser';
    } else {
      name = firstValue([
        'computerName',
        'name',
        'model',
        'productName',
        'prettyName',
        'device',
      ]);
    }

    final reportedPlatform = firstValue([
      'platform',
      'systemName',
      'prettyName',
      'osRelease',
      'version',
    ]);

    return _DeviceDetails(
      name: name.isEmpty ? '$platform device' : name,
      type: kIsWeb
          ? 'Web browser'
          : (defaultTargetPlatform == TargetPlatform.android ||
                    defaultTargetPlatform == TargetPlatform.iOS
                ? 'Mobile app'
                : 'Desktop app'),
      platform: reportedPlatform.isEmpty
          ? platform
          : '$platform ($reportedPlatform)',
      appVersion: '${package.version}+${package.buildNumber}',
    );
  }

  static String _platformLabel() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.linux:
        return 'Linux';
      case TargetPlatform.fuchsia:
        return 'Fuchsia';
    }
  }

  static String _titleCase(String value) {
    final normalized = value.replaceAll('_', ' ').trim();
    if (normalized.isEmpty) return normalized;
    return '${normalized[0].toUpperCase()}${normalized.substring(1)}';
  }
}

class _LocalSessionIdentity {
  final String authUid;
  final String sessionToken;
  final String deviceId;

  const _LocalSessionIdentity({
    required this.authUid,
    required this.sessionToken,
    required this.deviceId,
  });
}

class _DeviceDetails {
  final String name;
  final String type;
  final String platform;
  final String appVersion;

  const _DeviceDetails({
    required this.name,
    required this.type,
    required this.platform,
    required this.appVersion,
  });
}
