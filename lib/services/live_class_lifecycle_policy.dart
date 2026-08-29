class LiveClassLifecyclePolicy {
  const LiveClassLifecyclePolicy._();

  /// The teacher updates their presence every 30 seconds while the room is
  /// running. A wider window prevents a brief network handoff from hiding a
  /// valid class while still expiring abandoned `is_live: true` records.
  static const Duration teacherPresenceTimeout = Duration(minutes: 2);
  static const Duration _allowedFutureClockSkew = Duration(minutes: 5);

  static bool isActiveSnapshot(Object? value) {
    return value is Map && value['is_live'] == true;
  }

  /// The student dashboard must offer an active class for its full lifetime,
  /// including when the student opens the app after the incoming-call alert.
  /// Teacher presence is intentionally not checked here: presence timestamps
  /// are only a safeguard for notification delivery and can be delayed by
  /// mobile/web timer throttling. The teacher ends the dashboard offer by
  /// setting `is_live` to false or removing the live-class record.
  static bool shouldShowStudentJoinOption(Object? value) {
    return isActiveSnapshot(value);
  }

  static bool isJoinableSnapshot(
    Object? value, {
    DateTime? now,
    Duration presenceTimeout = teacherPresenceTimeout,
  }) {
    if (!isActiveSnapshot(value)) {
      return false;
    }

    final participants = (value as Map)['participants'];
    if (participants is! Map) {
      return false;
    }

    final nowMilliseconds = (now ?? DateTime.now()).millisecondsSinceEpoch;
    for (final participantValue in participants.values) {
      if (participantValue is! Map ||
          participantValue['role']?.toString() != 'teacher') {
        continue;
      }

      final lastSeen = _timestampMilliseconds(participantValue['last_seen']);
      if (lastSeen == null) {
        continue;
      }

      final ageMilliseconds = nowMilliseconds - lastSeen;
      if (ageMilliseconds <= presenceTimeout.inMilliseconds &&
          ageMilliseconds >= -_allowedFutureClockSkew.inMilliseconds) {
        return true;
      }
    }

    return false;
  }

  static bool shouldCloseStudentRoom({
    required bool firebaseConnected,
    required Object? classSnapshot,
  }) {
    return firebaseConnected && !isActiveSnapshot(classSnapshot);
  }

  static int? _timestampMilliseconds(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}
