import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:uuid/uuid.dart';

class CallManager {
  static StreamSubscription<CallEvent?>? _eventSubscription;
  static void Function(Map<String, dynamic>?)? _onAccept;
  static final Set<String> _handledAcceptedCalls = <String>{};

  static Future<void> prepareIncomingCallUi() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await FlutterCallkitIncoming.requestNotificationPermission(<
      String,
      dynamic
    >{
      'title': 'Class Call Notifications',
      'rationaleMessagePermission':
          'Notification permission is needed so students can receive live class calls.',
      'postNotificationMessageRequired':
          'Please enable notifications in settings to receive live class calls.',
    });

    final canUseFullScreenIntent =
        await FlutterCallkitIncoming.canUseFullScreenIntent();
    if (canUseFullScreenIntent == true) {
      return;
    }

    await FlutterCallkitIncoming.requestFullIntentPermission();
  }

  static Future<void> showIncomingCall({
    required String name,
    required String classId,
    required String topic,
    String? startedAt,
  }) async {
    final uuid = const Uuid().v4();

    final params = CallKitParams(
      id: uuid,
      nameCaller: name,
      appName: 'Scholars Academy',
      // No avatar / backgroundUrl – network image fetches block the
      // notification from appearing in the background isolate.
      handle: topic,
      type: 1,
      duration: 120000,
      textAccept: 'Join Class',
      textDecline: 'Decline',
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Missed live class',
      ),
      extra: <String, dynamic>{
        'classId': classId,
        'topic': topic,
        if (startedAt != null && startedAt.isNotEmpty) 'startedAt': startedAt,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#09122C',
        actionColor: '#E91E63',
        incomingCallNotificationChannelName: 'Incoming Call',
        missedCallNotificationChannelName: 'Missed Call',
        isShowFullLockedScreen: true,
      ),
      ios: const IOSParams(
        iconName: 'AppIcon',
        handleType: 'generic',
        supportsVideo: true,
        maximumCallGroups: 2,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: true,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  static void listenToCallEvents(
    void Function(Map<String, dynamic>?) onAccept,
  ) {
    _onAccept = onAccept;
    _eventSubscription ??= FlutterCallkitIncoming.onEvent.listen(
      _handleCallEvent,
    );
  }

  static Future<Map<String, dynamic>?> takeAcceptedCallFromActiveCalls() async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    if (calls is! List || calls.isEmpty) {
      return null;
    }

    for (final dynamic rawCall in calls.reversed) {
      final call = _normalizeMap(rawCall);
      if (call == null || call['isAccepted'] != true) {
        continue;
      }

      final extra = _normalizeMap(call['extra']);
      final callId = call['id']?.toString();
      if (!_markAcceptedCallHandled(callId, extra)) {
        continue;
      }

      if (callId != null && callId.isNotEmpty) {
        await FlutterCallkitIncoming.endCall(callId);
      }

      return extra;
    }

    return null;
  }

  static Future<void> _handleCallEvent(CallEvent? event) async {
    if (event == null || event.event != Event.actionCallAccept) {
      return;
    }

    final body = _normalizeMap(event.body);
    final extra = _normalizeMap(body?['extra']);
    final callId = body?['id']?.toString();

    if (!_markAcceptedCallHandled(callId, extra)) {
      return;
    }

    if (callId != null && callId.isNotEmpty) {
      unawaited(FlutterCallkitIncoming.endCall(callId));
    }

    _onAccept?.call(extra);
  }

  static bool _markAcceptedCallHandled(
    String? callId,
    Map<String, dynamic>? extra,
  ) {
    final handledKeys = <String>{
      if (callId != null && callId.isNotEmpty) callId,
    };

    final liveKey = _buildLiveKey(extra);
    if (liveKey != null) {
      handledKeys.add(liveKey);
    }

    if (handledKeys.any(_handledAcceptedCalls.contains)) {
      return false;
    }

    _handledAcceptedCalls.addAll(handledKeys);
    return true;
  }

  static String? _buildLiveKey(Map<String, dynamic>? extra) {
    if (extra == null) {
      return null;
    }

    final classId = extra['classId']?.toString();
    final startedAt = extra['startedAt']?.toString();
    if (classId == null || classId.isEmpty) {
      return null;
    }
    if (startedAt == null || startedAt.isEmpty) {
      return null;
    }

    return '$classId:$startedAt';
  }

  static Map<String, dynamic>? _normalizeMap(dynamic value) {
    if (value is! Map) {
      return null;
    }

    return value.map<String, dynamic>(
      (dynamic key, dynamic mapValue) => MapEntry(key.toString(), mapValue),
    );
  }
}
