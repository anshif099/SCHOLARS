import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/services/live_class_media_policy.dart';

void main() {
  test('keeps full teacher quality for a small class', () {
    final limits = liveClassVideoLimits(isTeacher: true, studentCount: 2);

    expect(limits.maxBitrate, 500 * 1000);
    expect(limits.maxFrameRate, 30);
  });

  test('reduces teacher uplink usage as the class grows', () {
    final medium = liveClassVideoLimits(isTeacher: true, studentCount: 9);
    final large = liveClassVideoLimits(isTeacher: true, studentCount: 11);

    expect(medium.maxBitrate, 200 * 1000);
    expect(medium.maxFrameRate, 20);
    expect(large.maxBitrate, 150 * 1000);
    expect(large.maxFrameRate, 15);
  });

  test('student camera uses one conservative teacher-only stream', () {
    final limits = liveClassVideoLimits(isTeacher: false, studentCount: 40);

    expect(limits.maxBitrate, 180 * 1000);
    expect(limits.maxFrameRate, 15);
  });
}
