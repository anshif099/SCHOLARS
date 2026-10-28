import 'dart:async';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/services/recording_upload.dart';

class TestSnapshot extends Fake implements TaskSnapshot {
  @override
  int get totalBytes => 100;
  @override
  int get bytesTransferred => 47;
}

class TestUploadTask extends Fake implements UploadTask {
  final completed = Completer<TaskSnapshot>();
  final events = StreamController<TaskSnapshot>.broadcast();
  bool isPaused = false;
  @override
  Stream<TaskSnapshot> get snapshotEvents => events.stream;
  @override
  Future<bool> pause() async {
    isPaused = true;
    return true;
  }

  @override
  Future<bool> resume() async {
    isPaused = false;
    return true;
  }

  @override
  Future<S> then<S>(
    FutureOr<S> Function(TaskSnapshot) onValue, {
    Function? onError,
  }) => completed.future.then(onValue, onError: onError);
}

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  tearDown(() => RecordingUpload.jobs.clear());

  test(
    'connection loss pauses the same upload and reconnect resumes it',
    () async {
      final network = StreamController<bool>.broadcast();
      final task = TestUploadTask();
      var saves = 0;
      final foreground = <bool>[];
      late RecordingUpload job;
      job = RecordingUpload.forTesting(
        'recording',
        () async {
          saves++;
          await job.track(task);
          return true;
        },
        connections: network.stream,
        keepAlive: (value) async {
          foreground.add(value);
        },
      );
      RecordingUpload.jobs[job.id] = job;
      final finished = job.start();
      await flush();
      task.events.add(TestSnapshot());
      await flush();
      expect(job.progress, 47);
      network.add(false);
      await flush();
      expect(task.isPaused, isTrue);
      expect(job.label, contains('Offline'));
      network.add(true);
      await flush();
      expect(task.isPaused, isFalse);
      expect(saves, 1);
      task.completed.complete(TestSnapshot());
      await finished;
      expect(RecordingUpload.jobs, isEmpty);
      expect(job.completed, isTrue);
      expect(job.progress, 100);
      expect(foreground, [true, false]);
      await task.events.close();
      await network.close();
    },
  );

  test('manual pause survives reconnect until teacher continues', () async {
    final network = StreamController<bool>.broadcast();
    final task = TestUploadTask();
    late RecordingUpload job;
    job = RecordingUpload.forTesting(
      'recording',
      () async {
        await job.track(task);
        return true;
      },
      connections: network.stream,
      keepAlive: (_) async {},
    );
    RecordingUpload.jobs[job.id] = job;
    final finished = job.start();
    await flush();
    await job.togglePause();
    network.add(false);
    network.add(true);
    await flush();
    expect(task.isPaused, isTrue);
    await job.togglePause();
    expect(task.isPaused, isFalse);
    task.completed.complete(TestSnapshot());
    await finished;
    await task.events.close();
    await network.close();
  });

  test(
    'failed save stays retryable and duplicate starts do not duplicate work',
    () async {
      final network = StreamController<bool>.broadcast();
      var attempts = 0;
      final saved = Completer<bool>();
      final job = RecordingUpload.forTesting(
        'recording',
        () {
          attempts++;
          return attempts == 1 ? Future.value(false) : saved.future;
        },
        connections: network.stream,
        keepAlive: (_) async {},
      );
      RecordingUpload.jobs[job.id] = job;
      await job.start();
      expect(job.failed, isTrue);
      expect(job.completed, isFalse);
      expect(RecordingUpload.jobs[job.id], same(job));
      final retry = job.start();
      await job.start();
      await flush();
      expect(attempts, 2);
      saved.complete(true);
      await retry;
      expect(RecordingUpload.jobs, isEmpty);
      await network.close();
    },
  );
}
