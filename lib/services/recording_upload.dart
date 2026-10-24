import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-scoped ownership: navigating away from the call never cancels an upload.
class RecordingUpload extends ChangeNotifier {
  RecordingUpload._(this.id, this._save)
    : _connections = (() => FirebaseDatabase.instance
          .ref('.info/connected')
          .onValue
          .map((event) => event.snapshot.value == true)),
      _keepAlive = _foreground;

  @visibleForTesting
  RecordingUpload.forTesting(
    this.id,
    this._save, {
    required Stream<bool> connections,
    required Future<void> Function(bool) keepAlive,
  }) : _connections = (() => connections),
       _keepAlive = keepAlive;

  final Stream<bool> Function() _connections;
  final Future<void> Function(bool) _keepAlive;
  Future<void> _taskChanges = Future<void>.value();

  static final Map<String, RecordingUpload> jobs = {};
  static const _channel = MethodChannel(
    'com.academy.scholars/recording_upload',
  );
  final String id;
  final Future<bool> Function() _save;
  UploadTask? _task;
  bool online = true;
  bool paused = false;
  bool running = false;
  bool failed = false;
  int progress = 0;

  String get label => !online
      ? 'Offline — upload paused ($progress%)'
      : paused
      ? 'Upload paused ($progress%)'
      : failed
      ? 'Upload failed — retry'
      : 'Uploading $progress%';

  static RecordingUpload enqueue(String id, Future<bool> Function() save) {
    final existing = jobs[id];
    if (existing != null) return existing;
    final job = RecordingUpload._(id, save);
    jobs[id] = job;
    unawaited(job.start());
    return job;
  }

  static Future<void> _foreground(bool start) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(start ? 'start' : 'stop');
    } catch (error) {
      debugPrint('Upload foreground service: $error');
    }
  }

  Future<void> start() async {
    if (running) return;
    running = true;
    failed = false;
    notifyListeners();
    await _keepAlive(true);
    final connection = _connections().listen((connected) {
      online = connected;
      unawaited(_syncTask());
      notifyListeners();
    });
    try {
      final saved = await _save();
      failed = !saved;
      if (saved) jobs.remove(id);
    } catch (error) {
      failed = true;
      debugPrint('Background recording upload: $error');
    } finally {
      await connection.cancel();
      _task = null;
      running = false;
      notifyListeners();
      if (!jobs.values.any((job) => job.running)) await _keepAlive(false);
    }
  }

  Future<void> togglePause() async {
    paused = !paused;
    await _syncTask();
    notifyListeners();
  }

  Future<void> _syncTask() {
    // Serialize network changes and button taps so a late pause cannot undo resume.
    _taskChanges = _taskChanges.then((_) async {
      final task = _task;
      if (task == null) return;
      try {
        if (paused || !online) {
          await task.pause();
        } else {
          await task.resume();
        }
      } catch (error) {
        debugPrint('Upload pause/resume: $error');
      }
    });
    return _taskChanges;
  }

  Future<TaskSnapshot> track(UploadTask task) async {
    _task = task;
    await _syncTask();
    final subscription = task.snapshotEvents.listen((snapshot) {
      progress = snapshot.totalBytes <= 0
          ? 0
          : (snapshot.bytesTransferred * 100 ~/ snapshot.totalBytes).clamp(
              0,
              100,
            );
      notifyListeners();
    });
    try {
      return await task;
    } finally {
      await subscription.cancel();
      if (identical(_task, task)) _task = null;
    }
  }
}
