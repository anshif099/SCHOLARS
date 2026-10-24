@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
// This browser-only test wraps a generated browser MediaStream.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/web/factory_impl.dart' show MediaStreamWeb;
import 'package:web/web.dart' as web;

void main() {
  testWidgets('mounted remote stream reports its first decoded video frame', (
    tester,
  ) async {
    final canvas = web.HTMLCanvasElement()
      ..width = 160
      ..height = 90;
    final context = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    final captured = canvas.captureStream(15);
    final stream = MediaStreamWeb(captured, 'remote');
    final renderer = RTCVideoRenderer();
    final firstFrame = Completer<void>();
    var framesReported = 0;
    renderer.onFirstFrameRendered = () {
      framesReported++;
      if (!firstFrame.isCompleted) firstFrame.complete();
    };
    await renderer.initialize();
    renderer.srcObject = stream;

    // The view must be mounted before a first-frame callback can arrive.
    expect(framesReported, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(width: 320, height: 180, child: RTCVideoView(renderer)),
      ),
    );
    await tester.runAsync(() async {
      final drawing = Timer.periodic(const Duration(milliseconds: 60), (_) {
        context.fillStyle = 'red'.toJS;
        context.fillRect(0, 0, 160, 90);
      });
      try {
        await firstFrame.future.timeout(const Duration(seconds: 10));
      } finally {
        drawing.cancel();
      }
    });
    expect(renderer.videoWidth, 160);
    expect(renderer.videoHeight, 90);
    expect(framesReported, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    for (final track in captured.getTracks().toDart) {
      track.stop();
    }
    await renderer.dispose();
  });
  testWidgets(
    'front-to-rear camera switch clears the existing mirror immediately',
    (tester) async {
      final canvas = web.HTMLCanvasElement()
        ..width = 160
        ..height = 90;
      final captured = canvas.captureStream(15);
      final stream = MediaStreamWeb(captured, 'local');
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      renderer.srcObject = stream;
      // HtmlElementView is not attached to the DOM in a widget test. Supply its
      // video element explicitly to exercise the renderer's actual CSS updates.
      final element = web.HTMLVideoElement()
        ..id = 'video_RTCVideoRenderer-${renderer.textureId}';
      web.document.body!.append(element);
      Future<void> showCamera(bool front) => tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 180,
            child: RTCVideoView(renderer, mirror: front),
          ),
        ),
      );
      await showCamera(true);
      expect(element.style.transform, 'scaleX(-1)');
      await showCamera(false);
      expect(element.style.transform, 'none');
      await showCamera(true);
      expect(element.style.transform, 'scaleX(-1)');
      await showCamera(false);
      expect(element.style.transform, 'none');
      renderer.srcObject = stream;
      expect(element.style.transform, 'none');
      await tester.pumpWidget(const SizedBox.shrink());
      for (final track in captured.getTracks().toDart) {
        track.stop();
      }
      await renderer.dispose();
      element.remove();
    },
  );
}
