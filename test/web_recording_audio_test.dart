@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:dart_webrtc/src/media_stream_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scholars/services/web_recording_helper.dart';
import 'package:web/web.dart' as web;

void main() {
  test(
    'web recording retains audio across pause and resume and excludes paused time',
    () async {
      final context = web.AudioContext();
      final destination = context.createMediaStreamDestination();
      final oscillator = context.createOscillator();
      oscillator.connect(destination);
      oscillator.start();
      await context.resume().toDart.timeout(const Duration(seconds: 5));

      final canvas = web.HTMLCanvasElement()
        ..width = 160
        ..height = 90;
      final drawingContext =
          canvas.getContext('2d') as web.CanvasRenderingContext2D;
      final stream = canvas.captureStream(15);
      for (final track in destination.stream.getAudioTracks().toDart) {
        stream.addTrack(track);
      }
      final drawing = Timer.periodic(const Duration(milliseconds: 60), (_) {
        drawingContext.fillStyle = 'red'.toJS;
        drawingContext.fillRect(0, 0, 160, 90);
      });
      final recorder = WebRecordingHelper();
      try {
        await recorder.start(null, MediaStreamWeb(stream, 'local'));
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await recorder.setPaused(true);
        await Future<void>.delayed(const Duration(seconds: 2));
        await recorder.setPaused(false);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final blob = await recorder.stop() as web.Blob;
        expect(blob.size, greaterThan(0));
        final data = await blob.arrayBuffer().toDart;
        final audio = await context.decodeAudioData(data).toDart;
        expect(audio.duration, greaterThan(2.5));
        expect(audio.duration, lessThan(4));
        final samples = audio.getChannelData(0).toDart;

        double rms(double startFraction, double endFraction) {
          final start = (samples.length * startFraction).floor();
          final end = (samples.length * endFraction).floor();
          var energy = 0.0;
          for (var index = start; index < end; index++) {
            energy += samples[index] * samples[index];
          }
          return math.sqrt(energy / (end - start));
        }

        expect(
          rms(0.1, 0.3),
          greaterThan(0.05),
          reason: 'Opening audio is silent',
        );
        expect(
          rms(0.4, 0.6),
          greaterThan(0.05),
          reason: 'Middle audio is silent',
        );
        expect(
          rms(0.7, 0.9),
          greaterThan(0.05),
          reason: 'Ending audio is silent',
        );

        final video = web.HTMLVideoElement()
          ..muted = true
          ..preload = 'auto';
        final url = web.URL.createObjectURL(blob);
        try {
          final firstFrame = Completer<void>();
          video.onloadeddata = ((web.Event event) {
            if (!firstFrame.isCompleted) firstFrame.complete();
          }).toJS;
          video.src = url;
          video.load();
          await firstFrame.future.timeout(const Duration(seconds: 10));
          expect(video.videoWidth, 160);
          expect(video.videoHeight, 90);

          final lastFrame = Completer<void>();
          video.onseeked = ((web.Event event) {
            if (!lastFrame.isCompleted) lastFrame.complete();
          }).toJS;
          video.currentTime = audio.duration * 0.8;
          await lastFrame.future.timeout(const Duration(seconds: 10));
          expect(video.readyState, greaterThanOrEqualTo(2));
          expect(video.currentTime, greaterThan(2));
        } finally {
          video.src = '';
          video.load();
          web.URL.revokeObjectURL(url);
        }
      } finally {
        drawing.cancel();
        oscillator.stop();
        for (final track in stream.getTracks().toDart) {
          track.stop();
        }
        await context.close().toDart;
      }
    },
  );
}
