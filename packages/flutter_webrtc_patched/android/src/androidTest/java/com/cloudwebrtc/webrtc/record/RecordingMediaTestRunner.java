package com.cloudwebrtc.webrtc.record;

import android.app.Activity;
import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.media.AudioFormat;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.os.Bundle;
import android.os.SystemClock;

import org.webrtc.EglBase;
import org.webrtc.JavaI420Buffer;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.VideoFrame;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.io.File;
import java.nio.ByteBuffer;

/** Exercises the real Android codecs and MP4 muxer without a camera or mic. */
public class RecordingMediaTestRunner extends Instrumentation {
    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        EglBase egl = null;
        try {
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions
                    .builder(getTargetContext()).createInitializationOptions());
            egl = EglBase.create();
            File directory = new File(getTargetContext().getFilesDir(), "recording-tests");
            if (!directory.isDirectory() && !directory.mkdirs()) {
                throw new IllegalStateException("Cannot create recording test directory");
            }
            record(directory, "audio-gap", egl.getEglBaseContext(), 6000, 0, true);
            record(directory, "late-audio", egl.getEglBaseContext(), 6000, 3000, false);
            record(directory, "no-audio", egl.getEglBaseContext(), 3000, 4000, false);
            record(directory, "format-changes", egl.getEglBaseContext(), 6000, 0, false);
            MediaRecorderImpl.verifyRecordedAudio(new File(directory, "format-changes.mp4"));
            boolean missingAudioRejected = false;
            try {
                MediaRecorderImpl.verifyRecordedAudio(new File(directory, "no-audio.mp4"));
            } catch (java.io.IOException expected) {
                missingAudioRejected = true;
            }
            require(missingAudioRejected, "A recording without audio was incorrectly accepted");
            result.putString("stream", "PASS: audio gap, delayed audio, video-only recording, changing PCM formats; "
                    + "saved video frames decode at both ends. Files: " + directory);
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL: " + android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        } finally {
            if (egl != null) egl.release();
        }
    }

    private void record(File directory, String name, EglBase.Context egl,
                        int durationMs, int audioStartMs, boolean audioGap) throws Exception {
        File output = new File(directory, name + ".mp4");
        VideoFileRenderer renderer = new VideoFileRenderer(output.getAbsolutePath(), egl, true);
        // Configure the cold video codec before measuring the capture interval.
        // onFrame performs synchronous codec setup; MP4 removes the initial
        // empty lead-in, so including that setup time shortens the saved clip.
        JavaI420Buffer openingBuffer = JavaI420Buffer.allocate(160, 90);
        fill(openingBuffer.getDataY(), (byte) 40);
        fill(openingBuffer.getDataU(), (byte) 128);
        fill(openingBuffer.getDataV(), (byte) 128);
        VideoFrame openingFrame = new VideoFrame(openingBuffer, 0, System.nanoTime());
        renderer.onFrame(openingFrame);
        openingFrame.release();
        long startedAt = System.nanoTime();
        long nextVideo = 0;
        try {
            while ((System.nanoTime() - startedAt) / 1000000L < durationMs) {
                long elapsed = (System.nanoTime() - startedAt) / 1000000L;
                if (elapsed >= nextVideo) {
                    JavaI420Buffer buffer = JavaI420Buffer.allocate(160, 90);
                    fill(buffer.getDataY(), (byte) (40 + elapsed / 100 % 160));
                    fill(buffer.getDataU(), (byte) 128);
                    fill(buffer.getDataV(), (byte) 128);
                    VideoFrame frame = new VideoFrame(buffer, 0, System.nanoTime());
                    renderer.onFrame(frame);
                    frame.release();
                    nextVideo = elapsed + 66;
                }
                if (elapsed >= audioStartMs && !(audioGap && elapsed >= 2000 && elapsed < 3000)) {
                    byte[] pcm = new byte[960];
                    for (int index = 0; index < 480; index++) {
                        double time = elapsed / 1000.0 + index / 48000.0;
                        short value = (short) (12000 * Math.sin(2 * Math.PI * 440 * time));
                        pcm[index * 2] = (byte) value;
                        pcm[index * 2 + 1] = (byte) (value >> 8);
                    }
                    if (name.equals("format-changes") && elapsed < 3000) {
                        // Playback can arrive before the mic, in stereo float
                        // at 44.1 kHz; microphone callbacks then switch to mono
                        // 48 kHz PCM16. AAC must retain one stable format.
                        ByteBuffer floats = ByteBuffer.allocate(441 * 2 * 4)
                                .order(java.nio.ByteOrder.LITTLE_ENDIAN);
                        for (int frame = 0; frame < 441; frame++) {
                            float value = (float) (0.4 * Math.sin(2 * Math.PI * 440
                                    * (elapsed / 1000.0 + frame / 44100.0)));
                            floats.putFloat(value);
                            floats.putFloat(value);
                        }
                        renderer.onWebRtcAudioRecordSamplesReady(
                                new JavaAudioDeviceModule.AudioSamples(
                                        AudioFormat.ENCODING_PCM_FLOAT, 2, 44100, floats.array()));
                    } else {
                        renderer.onWebRtcAudioRecordSamplesReady(
                                new JavaAudioDeviceModule.AudioSamples(
                                        AudioFormat.ENCODING_PCM_16BIT, 1, 48000, pcm));
                    }
                }
                SystemClock.sleep(10);
            }
        } finally {
            renderer.release();
        }
        check(output, durationMs, audioStartMs < durationMs, audioStartMs);
    }

    private void fill(ByteBuffer buffer, byte value) {
        while (buffer.hasRemaining()) buffer.put(value);
        buffer.rewind();
    }

    private void check(File file, int durationMs, boolean expectAudio, int audioStartMs) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(file.getAbsolutePath());
            int audio = -1;
            int video = -1;
            for (int track = 0; track < extractor.getTrackCount(); track++) {
                String mime = extractor.getTrackFormat(track).getString(MediaFormat.KEY_MIME);
                if (mime.startsWith("audio/")) audio = track;
                if (mime.startsWith("video/")) video = track;
            }
            require(video >= 0, "Missing video track: " + file);
            require((audio >= 0) == expectAudio, "Unexpected audio track: " + file);
            long[] videoTimes = trackTimes(extractor, video);
            // A cold emulator may spend over 500 ms initializing its encoder.
            // Still require opening video before the delayed-audio scenario's
            // three-second microphone start, catching discarded pending frames.
            require(videoTimes[0] < 1500000,
                    "Opening video was discarded (first PTS " + videoTimes[0] + "): " + file);
            require(videoTimes[1] > (durationMs - 500) * 1000L,
                    "Ending video is missing (last PTS " + videoTimes[1] + "): " + file);
            if (expectAudio) {
                MediaFormat audioFormat = extractor.getTrackFormat(audio);
                require(audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) == 48000
                                && audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 1,
                        "Recording audio format changed: " + file);
                long[] audioTimes = trackTimes(extractor, audio);
                require(audioTimes[0] >= (audioStartMs - 300) * 1000L,
                        "Audio shifted before capture: " + file);
                require(audioTimes[1] > (durationMs - 500) * 1000L,
                        "Audio ends early after dropped callbacks: " + file);
                require(audioTimes[1] < (durationMs + 500) * 1000L,
                        "Audio timeline extends beyond the video: " + file);
            }
        } finally {
            extractor.release();
        }
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            retriever.setDataSource(file.getAbsolutePath());
            for (long timeUs : new long[]{300000, (durationMs - 400) * 1000L}) {
                Bitmap frame = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST);
                require(frame != null && frame.getWidth() > 0, "Video did not decode: " + file);
                frame.recycle();
            }
        } finally {
            retriever.release();
        }
    }

    private long[] trackTimes(MediaExtractor extractor, int track) {
        extractor.selectTrack(track);
        extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC);
        long first = extractor.getSampleTime();
        long last = first;
        while (extractor.getSampleTime() >= 0) {
            last = extractor.getSampleTime();
            if (!extractor.advance()) break;
        }
        extractor.unselectTrack(track);
        return new long[]{first, last};
    }

    private void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
