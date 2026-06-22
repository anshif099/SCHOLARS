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
import java.nio.ByteBuffer;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

class VideoFileRenderer implements VideoSink, SamplesReadyCallback {
    private static final String TAG = "VideoFileRenderer";
    private static final long RELEASE_TIMEOUT_MS = 5000;
    private static final long AUDIO_DRAIN_TIMEOUT_US = 0L;
    private static final long AUDIO_FINAL_DRAIN_TIMEOUT_US = 10000L;
    private static final int AUDIO_FINAL_DRAIN_MAX_TRIES = 200;
    private final Object muxerLock = new Object();
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
    private boolean isRunning = true;
    private GlRectDrawer drawer;
    private Surface surface;
    private MediaCodec audioEncoder;

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
        frame.retain();
        if (outputFileWidth == -1) {
            setOutputSize(frame);
            initVideoEncoder();
        }
        renderThreadHandler.post(() -> renderFrameOnRenderThread(frame));
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
            if (firstRenderedFrameWallClockNs == 0L) {
                firstRenderedFrameWallClockNs = nowNs;
            }
            lastRenderedFrameWallClockNs = nowNs;

            if (frameDrawer == null) {
                frameDrawer = new VideoFrameDrawer();
            }
            long presentationTimeNs = nowNs - firstRenderedFrameWallClockNs;
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
    private long videoFrameStartUs = 0L;
    private boolean hasVideoFrameStart = false;
    private long lastRenderedFrameWallClockNs = 0L;
    private long firstRenderedFrameWallClockNs = 0L;
    private long lastVideoPresentationTimeNs = -1L;
    private long lastWrittenVideoPresentationTimeUs = -1L;
    private long audioFrameStartUs = 0L;
    private boolean hasAudioFrameStart = false;
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
            if (muxerStarted || trackIndex == -1 || audioTrackIndex == -1) {
                return;
            }
            mediaMuxer.start();
            muxerStarted = true;
        }
    }

    private void writeSampleDataSafely(int currentTrackIndex, ByteBuffer encodedData, MediaCodec.BufferInfo currentBufferInfo) {
        synchronized (muxerLock) {
            if (!muxerStarted) {
                return;
            }
            mediaMuxer.writeSampleData(currentTrackIndex, encodedData, currentBufferInfo);
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
                    if (muxerStarted) {
                        if (!hasVideoFrameStart) {
                            videoFrameStartUs = bufferInfo.presentationTimeUs;
                            hasVideoFrameStart = true;
                        }
                        bufferInfo.presentationTimeUs -= videoFrameStartUs;
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
                    if (muxerStarted && audioBufferInfo.size > 0) {
                        if (!hasAudioFrameStart) {
                            audioFrameStartUs = audioBufferInfo.presentationTimeUs;
                            hasAudioFrameStart = true;
                        }
                        audioBufferInfo.presentationTimeUs -= audioFrameStartUs;
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
        if (!isRunning)
            return;
        audioThreadHandler.post(() -> {
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
                audioEncoder.queueInputBuffer(bufferIndex, 0, data.length, presTime, 0);
                presTime += calculateAudioDurationUs(audioSamples, data.length);
            }
            drainAudio(false);
        });
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
