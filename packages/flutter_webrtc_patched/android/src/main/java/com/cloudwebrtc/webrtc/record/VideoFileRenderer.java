// Modifications by Signify, Copyright 2025, Signify Holding -  SPDX-License-Identifier: MIT

package com.cloudwebrtc.webrtc.record;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.AudioFormat;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import org.webrtc.EglBase;
import org.webrtc.GlRectDrawer;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;
import org.webrtc.VideoSink;
import org.webrtc.audio.JavaAudioDeviceModule;
import org.webrtc.audio.JavaAudioDeviceModule.SamplesReadyCallback;

import java.io.IOException;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

class VideoFileRenderer implements VideoSink, SamplesReadyCallback {
    private static final String TAG = "VideoFileRenderer";
    private static final long RELEASE_TIMEOUT_MS = 5000;
    private static final long AUDIO_DRAIN_TIMEOUT_US = 0L;
    private static final long AUDIO_FINAL_DRAIN_TIMEOUT_US = 10000L;
    private static final int AUDIO_FINAL_DRAIN_MAX_TRIES = 200;
    private final Object muxerLock = new Object();
    private final long recordingStartNs = System.nanoTime();
    // Keep encoded samples on disk until both track formats are known. This
    // preserves video when microphone callbacks start late or never arrive,
    // without retaining a whole silent class in memory.
    private final File pendingSamplesFile;
    private DataOutputStream pendingSamples;
    private final HandlerThread renderThread;
    private final Handler renderThreadHandler;
    private final HandlerThread audioThread;
    private final Handler audioThreadHandler;
    private int outputFileWidth = -1;
    private int outputFileHeight = -1;
    private ByteBuffer[] encoderOutputBuffers;
    private ByteBuffer[] audioInputBuffers;
    private ByteBuffer[] audioOutputBuffers;
    private EglBase eglBase;
    private final EglBase.Context sharedContext;
    private VideoFrameDrawer frameDrawer;

    private static final String MIME_TYPE = "video/avc";    // H.264 Advanced Video Coding
    private static final int TARGET_SHORT_EDGE = 360;
    private static final int TARGET_LONG_EDGE = 640;
    private static final int TARGET_KB_PER_MINUTE = 1000;
    private static final int AUDIO_BIT_RATE = 16 * 1000;
    private static final int TOTAL_BIT_RATE = TARGET_KB_PER_MINUTE * 1024 * 8 / 60;
    private static final int VIDEO_BIT_RATE =
            Math.max(96 * 1000, TOTAL_BIT_RATE - AUDIO_BIT_RATE);
    private static final int FRAME_RATE = 30;
    private static final int IFRAME_INTERVAL = 4;           // 4 seconds between I-frames
    private static final long FRAME_INTERVAL_NS = 1000000000L / FRAME_RATE;

    private final MediaMuxer mediaMuxer;
    private MediaCodec encoder;
    private final MediaCodec.BufferInfo bufferInfo;
    private MediaCodec.BufferInfo audioBufferInfo;
    private int trackIndex = -1;
    private int audioTrackIndex;
    private volatile boolean isRunning = true;
    private final AtomicBoolean framePending = new AtomicBoolean(false);
    private final AtomicInteger pendingAudioSamples = new AtomicInteger(0);
    private GlRectDrawer drawer;
    private Surface surface;
    private MediaCodec audioEncoder;
    private volatile boolean audioTrackUnavailable = false;

    VideoFileRenderer(String outputFile, final EglBase.Context sharedContext, boolean withAudio) throws IOException {
        renderThread = new HandlerThread(TAG + "RenderThread");
        renderThread.start();
        renderThreadHandler = new Handler(renderThread.getLooper());
        if (withAudio) {
            audioThread = new HandlerThread(TAG + "AudioThread");
            audioThread.start();
            audioThreadHandler = new Handler(audioThread.getLooper());
        } else {
            audioThread = null;
            audioThreadHandler = null;
        }
        bufferInfo = new MediaCodec.BufferInfo();
        this.sharedContext = sharedContext;

        // Create a MediaMuxer.  We can't add the video track and start() the muxer here,
        // because our MediaFormat doesn't have the Magic Goodies.  These can only be
        // obtained from the encoder after it has started processing data.
        mediaMuxer = new MediaMuxer(outputFile,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        pendingSamplesFile = File.createTempFile(
                "recording-pending-", ".bin", new File(outputFile).getParentFile());

        audioTrackIndex = withAudio ? -1 : 0;
    }

    private void initVideoEncoder() {
        MediaFormat format = MediaFormat.createVideoFormat(MIME_TYPE, outputFileWidth, outputFileHeight);

        // Set some properties.  Failing to specify some of these can cause the MediaCodec
        // configure() call to throw an unhelpful exception.
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, VIDEO_BIT_RATE);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IFRAME_INTERVAL);
        try {
            format.setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR);
        } catch (Exception e) {
            Log.w(TAG, "CBR bitrate mode is not supported by this encoder", e);
        }

        // Create a MediaCodec encoder, and configure it with our format.  Get a Surface
        // we can use for input and wrap it with a class that handles the EGL work.
        try {
            encoder = MediaCodec.createEncoderByType(MIME_TYPE);
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            renderThreadHandler.post(() -> {
                eglBase = EglBase.create(sharedContext, EglBase.CONFIG_RECORDABLE);
                surface = encoder.createInputSurface();
                eglBase.createSurface(surface);
                eglBase.makeCurrent();
                drawer = new GlRectDrawer();
            });
        } catch (Exception e) {
            Log.wtf(TAG, e);
        }
    }

    @Override
    public void onFrame(VideoFrame frame) {
        // Retained camera buffers must never accumulate behind a slow encoder.
        // A long class otherwise exhausts GPU/camera memory and kills the call.
        if (!isRunning || !framePending.compareAndSet(false, true)) return;
        frame.retain();
        if (outputFileWidth == -1) {
            setOutputSize(frame);
            initVideoEncoder();
        }
        if (!renderThreadHandler.post(() -> {
            try {
                renderFrameOnRenderThread(frame);
            } finally {
                framePending.set(false);
            }
        })) {
            frame.release();
            framePending.set(false);
        }
    }

    private void setOutputSize(VideoFrame frame) {
        int rotatedWidth = Math.max(2, frame.getRotatedWidth());
        int rotatedHeight = Math.max(2, frame.getRotatedHeight());
        if (rotatedWidth >= rotatedHeight) {
            outputFileHeight = TARGET_SHORT_EDGE;
            outputFileWidth = makeEven(Math.min(
                    TARGET_LONG_EDGE,
                    TARGET_SHORT_EDGE * rotatedWidth / rotatedHeight));
        } else {
            outputFileWidth = TARGET_SHORT_EDGE;
            outputFileHeight = makeEven(Math.min(
                    TARGET_LONG_EDGE,
                    TARGET_SHORT_EDGE * rotatedHeight / rotatedWidth));
        }
    }

    private int makeEven(int value) {
        return Math.max(2, value - (value % 2));
    }

    private void renderFrameOnRenderThread(VideoFrame frame) {
        try {
            if (eglBase == null || drawer == null || encoder == null) {
                return;
            }
            long nowNs = System.nanoTime();
            if (lastRenderedFrameWallClockNs != 0L
                    && nowNs - lastRenderedFrameWallClockNs < FRAME_INTERVAL_NS) {
                return;
            }
            lastRenderedFrameWallClockNs = nowNs;

            if (frameDrawer == null) {
                frameDrawer = new VideoFrameDrawer();
            }
            long presentationTimeNs = nowNs - recordingStartNs;
            if (lastVideoPresentationTimeNs >= 0L
                    && presentationTimeNs <= lastVideoPresentationTimeNs) {
                presentationTimeNs = lastVideoPresentationTimeNs + FRAME_INTERVAL_NS;
            }
            lastVideoPresentationTimeNs = presentationTimeNs;
            startEncoderIfNeeded();
            drainEncoder();
            frameDrawer.drawFrame(frame, drawer, null, 0, 0, outputFileWidth, outputFileHeight);
            eglBase.swapBuffers(presentationTimeNs);
            drainEncoder();
        } finally {
            frame.release();
        }
    }

    /**
     * Release all resources. All already posted frames will be rendered first.
     */
    // Start Signify modification
    void release() {
        isRunning = false;
        if (audioThreadHandler != null) {
            CountDownLatch audioLatch = new CountDownLatch(1);
            audioThreadHandler.post(() -> {
                try{
                    if (audioEncoder != null) {
                        drainAudio(false);
                        int bufferIndex = audioEncoder.dequeueInputBuffer(AUDIO_FINAL_DRAIN_TIMEOUT_US);
                        if (bufferIndex >= 0) {
                            audioEncoder.queueInputBuffer(
                                    bufferIndex,
                                    0,
                                    0,
                                    presTime,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            drainAudio(true);
                        }
                        audioEncoder.stop();
                        audioEncoder.release();
                        audioEncoder = null;
                    }
                    audioThread.quit();
                } finally {
                    audioLatch.countDown();
                }
            });
            try {
                if (!audioLatch.await(RELEASE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                    Log.w(TAG, "Timed out releasing audio encoder");
                    audioThread.quitSafely();
                }
            } catch (InterruptedException e) {
                Log.e(TAG, "Audio release interrupted", e);
                Thread.currentThread().interrupt();
            }
        }

        CountDownLatch renderLatch = new CountDownLatch(1);
        renderThreadHandler.post(() -> {
            try {
                if (encoder != null) {
                    if (encoderStarted) {
                        try {
                            encoder.signalEndOfInputStream();
                            drainEncoder();
                            // If no audio samples arrived during the complete
                            // recording, finalize a video-only MP4. Do not
                            // choose this before stop: microphone callbacks
                            // can start late on Android and MediaMuxer cannot
                            // add an audio track after it starts.
                            startVideoOnlyMuxerIfNeeded();
                            drainEncoder();
                        } catch (Exception e) {
                            Log.w(TAG, "Failed to signal video encoder EOS", e);
                        }
                    }
                    encoder.stop();
                    encoder.release();
                    encoder = null;
                }
                if (frameDrawer != null) {
                    frameDrawer.release();
                    frameDrawer = null;
                }
                if (drawer != null) {
                    drawer.release();
                    drawer = null;
                }
                if (surface != null) {
                    surface.release();
                    surface = null;
                }
                if (eglBase != null) {
                    eglBase.release();
                    eglBase = null;
                }
                synchronized (muxerLock) {
                    if (muxerStarted) {
                        mediaMuxer.stop();
                        muxerStarted = false;
                    }
                    mediaMuxer.release();
                    discardPendingSamples();
                }
                renderThread.quit();
            } finally {
                renderLatch.countDown();
            }
        });

        try {
            if (!renderLatch.await(RELEASE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "Timed out releasing video encoder");
                renderThread.quitSafely();
            }
        } catch (InterruptedException e) {
            Log.e(TAG, "Release interrupted", e);
            Thread.currentThread().interrupt();
        }
    }
    // End Signify modification

    private boolean encoderStarted = false;
    private volatile boolean muxerStarted = false;
    private long lastRenderedFrameWallClockNs = 0L;
    private long lastVideoPresentationTimeNs = -1L;
    private long lastWrittenVideoPresentationTimeUs = -1L;
    private long lastWrittenAudioPresentationTimeUs = -1L;

    private void startEncoderIfNeeded() {
        if (!encoderStarted) {
            encoder.start();
            encoderOutputBuffers = encoder.getOutputBuffers();
            encoderStarted = true;
        }
    }

    private void maybeStartMuxer() {
        synchronized (muxerLock) {
            if (muxerStarted || trackIndex == -1) {
                return;
            }
            if (audioTrackIndex == -1) {
                // Wait for audio's format callback. Video-only fallback is
                // selected during release, after the entire recording had a
                // chance to receive microphone samples.
                return;
            } else {
                mediaMuxer.start();
                muxerStarted = true;
                flushPendingSamples();
            }
        }
    }

    private void startVideoOnlyMuxerIfNeeded() {
        synchronized (muxerLock) {
            if (muxerStarted || trackIndex == -1 || audioTrackIndex != -1) {
                return;
            }
            audioTrackUnavailable = true;
            Log.w(TAG, "No audio samples arrived; finalizing recording as video-only");
            // A non-negative value means all required tracks are ready. Audio
            // callbacks are ignored once this video-only fallback is selected.
            audioTrackIndex = 0;
            mediaMuxer.start();
            muxerStarted = true;
            flushPendingSamples();
        }
    }

    private void writeSampleDataSafely(int currentTrackIndex, ByteBuffer encodedData, MediaCodec.BufferInfo currentBufferInfo) {
        synchronized (muxerLock) {
            if (!muxerStarted) {
                try {
                    if (pendingSamples == null) {
                        pendingSamples = new DataOutputStream(new BufferedOutputStream(
                                new FileOutputStream(pendingSamplesFile)));
                    }
                    byte[] data = new byte[currentBufferInfo.size];
                    encodedData.duplicate().get(data);
                    pendingSamples.writeInt(currentTrackIndex);
                    pendingSamples.writeInt(data.length);
                    pendingSamples.writeLong(currentBufferInfo.presentationTimeUs);
                    pendingSamples.writeInt(currentBufferInfo.flags);
                    pendingSamples.write(data);
                } catch (IOException e) {
                    throw new IllegalStateException("Could not preserve pending recording samples", e);
                }
                return;
            }
            mediaMuxer.writeSampleData(currentTrackIndex, encodedData, currentBufferInfo);
        }
    }

    // Called under muxerLock, before newer samples can be written.
    private void flushPendingSamples() {
        if (pendingSamples == null) return;
        try {
            pendingSamples.close();
            pendingSamples = null;
            try (DataInputStream input = new DataInputStream(new BufferedInputStream(
                    new FileInputStream(pendingSamplesFile)))) {
                while (true) {
                    int pendingTrack;
                    try {
                        pendingTrack = input.readInt();
                    } catch (EOFException end) {
                        break;
                    }
                    int size = input.readInt();
                    long timeUs = input.readLong();
                    int flags = input.readInt();
                    byte[] data = new byte[size];
                    input.readFully(data);
                    MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
                    info.set(0, size, timeUs, flags);
                    mediaMuxer.writeSampleData(pendingTrack, ByteBuffer.wrap(data), info);
                }
            }
        } catch (IOException e) {
            throw new IllegalStateException("Could not restore pending recording samples", e);
        } finally {
            discardPendingSamples();
        }
    }

    private void discardPendingSamples() {
        if (pendingSamples != null) {
            try {
                pendingSamples.close();
            } catch (IOException e) {
                Log.w(TAG, "Could not close pending samples", e);
            }
            pendingSamples = null;
        }
        if (pendingSamplesFile.exists() && !pendingSamplesFile.delete()) {
            Log.w(TAG, "Could not delete pending samples");
        }
    }

    private void drainEncoder() {
        if (!encoderStarted) {
            startEncoderIfNeeded();
            return;
        }
        while (true) {
            int encoderStatus = encoder.dequeueOutputBuffer(bufferInfo, 10000);
            if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break;
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                // not expected for an encoder
                encoderOutputBuffers = encoder.getOutputBuffers();
                Log.e(TAG, "encoder output buffers changed");
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // not expected for an encoder
                MediaFormat newFormat = encoder.getOutputFormat();

                Log.e(TAG, "encoder output format changed: " + newFormat);
                synchronized (muxerLock) {
                    if (trackIndex == -1) {
                        trackIndex = mediaMuxer.addTrack(newFormat);
                    }
                }
                maybeStartMuxer();
                if (!muxerStarted)
                    break;
            } else if (encoderStatus < 0) {
                Log.e(TAG, "unexpected result fr om encoder.dequeueOutputBuffer: " + encoderStatus);
            } else { // encoderStatus >= 0
                try {
                    ByteBuffer encodedData = encoderOutputBuffers[encoderStatus];
                    if (encodedData == null) {
                        Log.e(TAG, "encoderOutputBuffer " + encoderStatus + " was null");
                        break;
                    }
                    // It's usually necessary to adjust the ByteBuffer values to match BufferInfo.
                    encodedData.position(bufferInfo.offset);
                    encodedData.limit(bufferInfo.offset + bufferInfo.size);
                    if (bufferInfo.size > 0
                            && (bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                        if (bufferInfo.presentationTimeUs <= lastWrittenVideoPresentationTimeUs) {
                            bufferInfo.presentationTimeUs =
                                    lastWrittenVideoPresentationTimeUs + 1000000L / FRAME_RATE;
                        }
                        lastWrittenVideoPresentationTimeUs = bufferInfo.presentationTimeUs;
                        writeSampleDataSafely(trackIndex, encodedData, bufferInfo);
                    }
                    isRunning = isRunning && (bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0;
                    encoder.releaseOutputBuffer(encoderStatus, false);
                    if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        break;
                    }
                } catch (Exception e) {
                    Log.wtf(TAG, e);
                    break;
                }
            }
        }
    }

    private long presTime = 0L;

    private void drainAudio(boolean finalDrain) {
        if (audioTrackUnavailable) {
            return;
        }
        if (audioBufferInfo == null)
            audioBufferInfo = new MediaCodec.BufferInfo();
        long timeoutUs = finalDrain ? AUDIO_FINAL_DRAIN_TIMEOUT_US : AUDIO_DRAIN_TIMEOUT_US;
        int tryAgainCount = 0;
        while (true) {
            int encoderStatus = audioEncoder.dequeueOutputBuffer(audioBufferInfo, timeoutUs);
            if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!finalDrain || ++tryAgainCount >= AUDIO_FINAL_DRAIN_MAX_TRIES) {
                    break;
                }
                continue;
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                // not expected for an encoder
                audioOutputBuffers = audioEncoder.getOutputBuffers();
                Log.w(TAG, "encoder output buffers changed");
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // not expected for an encoder
                MediaFormat newFormat = audioEncoder.getOutputFormat();

                Log.w(TAG, "encoder output format changed: " + newFormat);
                synchronized (muxerLock) {
                    if (audioTrackUnavailable) {
                        return;
                    }
                    if (audioTrackIndex == -1) {
                        audioTrackIndex = mediaMuxer.addTrack(newFormat);
                    }
                }
                maybeStartMuxer();
                if (!muxerStarted)
                    break;
            } else if (encoderStatus < 0) {
                Log.e(TAG, "unexpected result fr om encoder.dequeueOutputBuffer: " + encoderStatus);
            } else { // encoderStatus >= 0
                try {
                    tryAgainCount = 0;
                    ByteBuffer encodedData = audioOutputBuffers[encoderStatus];
                    if (encodedData == null) {
                        Log.e(TAG, "encoderOutputBuffer " + encoderStatus + " was null");
                        break;
                    }
                    // It's usually necessary to adjust the ByteBuffer values to match BufferInfo.
                    encodedData.position(audioBufferInfo.offset);
                    encodedData.limit(audioBufferInfo.offset + audioBufferInfo.size);
                    if (!audioTrackUnavailable && audioBufferInfo.size > 0
                            && (audioBufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                        if (audioBufferInfo.presentationTimeUs <= lastWrittenAudioPresentationTimeUs) {
                            audioBufferInfo.presentationTimeUs =
                                    lastWrittenAudioPresentationTimeUs + 1L;
                        }
                        lastWrittenAudioPresentationTimeUs = audioBufferInfo.presentationTimeUs;
                        writeSampleDataSafely(audioTrackIndex, encodedData, audioBufferInfo);
                    }
                    isRunning = isRunning && (audioBufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0;
                    audioEncoder.releaseOutputBuffer(encoderStatus, false);
                    if ((audioBufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        break;
                    }
                } catch (Exception e) {
                    Log.wtf(TAG, e);
                    break;
                }
            }
        }
    }

    @Override
    public void onWebRtcAudioRecordSamplesReady(JavaAudioDeviceModule.AudioSamples audioSamples) {
        if (!isRunning || audioTrackUnavailable || audioThreadHandler == null)
            return;
        final long capturedAtUs = (System.nanoTime() - recordingStartNs) / 1000L;
        // Keep at most one second of 10 ms PCM callbacks queued on slow devices.
        if (pendingAudioSamples.incrementAndGet() > 100) {
            pendingAudioSamples.decrementAndGet();
            return;
        }
        if (!audioThreadHandler.post(() -> {
          try {
            if (audioEncoder == null) try {
                audioEncoder = MediaCodec.createEncoderByType("audio/mp4a-latm");
                MediaFormat format = new MediaFormat();
                format.setString(MediaFormat.KEY_MIME, "audio/mp4a-latm");
                format.setInteger(MediaFormat.KEY_CHANNEL_COUNT, audioSamples.getChannelCount());
                format.setInteger(MediaFormat.KEY_SAMPLE_RATE, audioSamples.getSampleRate());
                format.setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE);
                format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
                audioEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
                audioEncoder.start();
                audioInputBuffers = audioEncoder.getInputBuffers();
                audioOutputBuffers = audioEncoder.getOutputBuffers();
            } catch (IOException exception) {
                Log.wtf(TAG, exception);
                return;
            }
            drainAudio(false);
            int bufferIndex = audioEncoder.dequeueInputBuffer(0);
            if (bufferIndex >= 0) {
                ByteBuffer buffer = audioInputBuffers[bufferIndex];
                buffer.clear();
                byte[] data = audioSamples.getData();
                buffer.put(data);
                // Advance with capture time when callbacks are dropped or the
                // encoder is busy. Counting only accepted PCM compresses the
                // audio timeline and leaves a silent tail on long videos.
                long sampleTimeUs = Math.max(presTime, capturedAtUs);
                audioEncoder.queueInputBuffer(bufferIndex, 0, data.length, sampleTimeUs, 0);
                presTime = sampleTimeUs + calculateAudioDurationUs(audioSamples, data.length);
            }
            drainAudio(false);
          } catch (Exception e) {
            Log.e(TAG, "Could not encode recording audio", e);
          } finally {
            pendingAudioSamples.decrementAndGet();
          }
        })) {
            pendingAudioSamples.decrementAndGet();
        }
    }

    private long calculateAudioDurationUs(JavaAudioDeviceModule.AudioSamples audioSamples, int byteCount) {
        int bytesPerSample = audioSamples.getAudioFormat() == AudioFormat.ENCODING_PCM_FLOAT ? 4 : 2;
        int channelCount = Math.max(1, audioSamples.getChannelCount());
        int sampleRate = Math.max(1, audioSamples.getSampleRate());
        int frameSize = Math.max(1, bytesPerSample * channelCount);
        long frameCount = byteCount / frameSize;
        return frameCount * 1000000L / sampleRate;
    }

}
