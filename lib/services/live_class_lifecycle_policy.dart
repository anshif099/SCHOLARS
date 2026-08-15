class LiveClassLifecyclePolicy {
  const LiveClassLifecyclePolicy._();

  static bool isActiveSnapshot(Object? value) {
    return value is Map && value['is_live'] == true;
  }

  static bool shouldCloseStudentRoom({
    required bool firebaseConnected,
    required Object? classSnapshot,
  }) {
    return firebaseConnected && !isActiveSnapshot(classSnapshot);
  }
}
