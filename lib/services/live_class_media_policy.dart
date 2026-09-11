class LiveClassVideoLimits {
  const LiveClassVideoLimits({
    required this.maxBitrate,
    required this.maxFrameRate,
  });

  final int maxBitrate;
  final int maxFrameRate;
}

/// Keeps a peer-to-peer classroom inside a realistic mobile uplink budget.
///
/// The teacher sends one copy of the camera stream to every student. As the
/// room grows, each copy must therefore use less bandwidth. Students only send
/// one stream (to the teacher), but a conservative limit also protects the
/// teacher's aggregate download and decode workload.
LiveClassVideoLimits liveClassVideoLimits({
  required bool isTeacher,
  required int studentCount,
}) {
  if (!isTeacher) {
    return const LiveClassVideoLimits(maxBitrate: 180 * 1000, maxFrameRate: 15);
  }

  if (studentCount <= 2) {
    return const LiveClassVideoLimits(maxBitrate: 500 * 1000, maxFrameRate: 30);
  }
  if (studentCount <= 5) {
    return const LiveClassVideoLimits(maxBitrate: 300 * 1000, maxFrameRate: 24);
  }
  if (studentCount <= 10) {
    return const LiveClassVideoLimits(maxBitrate: 200 * 1000, maxFrameRate: 20);
  }
  return const LiveClassVideoLimits(maxBitrate: 150 * 1000, maxFrameRate: 15);
}
