package com.cloudwebrtc.webrtc.record;

import android.media.AudioFormat;
import android.os.SystemClock;

import com.cloudwebrtc.webrtc.audio.PlaybackSamplesReadyCallbackAdapter;

import org.webrtc.audio.JavaAudioDeviceModule;

import java.util.ArrayDeque;
import java.util.HashMap;

public class MixedAudioSamplesInterceptor
        implements RecorderAudioInterceptor,
        JavaAudioDeviceModule.SamplesReadyCallback,
        JavaAudioDeviceModule.PlaybackSamplesReadyCallback {
    private static final int OUTPUT_BUFFER_LIMIT_MS = 500;
    private static final int OUTPUT_ONLY_FALLBACK_MS = 120;

    private final AudioSamplesInterceptor inputSamplesInterceptor;
    private final PlaybackSamplesReadyCallbackAdapter playbackSamplesReadyCallbackAdapter;
    private final HashMap<Integer, JavaAudioDeviceModule.SamplesReadyCallback> callbacks =
            new HashMap<>();
    private final SampleBuffer playbackBuffer = new SampleBuffer();

    private int targetAudioFormat = AudioFormat.ENCODING_PCM_16BIT;
    private int targetChannelCount = 1;
    private int targetSampleRate = 48000;
    private boolean hasTargetFormat = false;
    private long lastInputSampleAtMs = 0L;

    public MixedAudioSamplesInterceptor(
            AudioSamplesInterceptor inputSamplesInterceptor,
            PlaybackSamplesReadyCallbackAdapter playbackSamplesReadyCallbackAdapter) {
        this.inputSamplesInterceptor = inputSamplesInterceptor;
        this.playbackSamplesReadyCallbackAdapter = playbackSamplesReadyCallbackAdapter;
    }

    @Override
    public void attachCallback(
            Integer id,
            JavaAudioDeviceModule.SamplesReadyCallback callback) throws Exception {
        boolean shouldAttachSources;
        synchronized (this) {
            shouldAttachSources = callbacks.isEmpty();
            callbacks.put(id, callback);
        }

        if (shouldAttachSources) {
            inputSamplesInterceptor.attachCallback(id, this);
            playbackSamplesReadyCallbackAdapter.addCallback(this);
        }
    }

    @Override
    public void detachCallback(Integer id) {
        boolean shouldDetachSources;
        synchronized (this) {
            callbacks.remove(id);
            shouldDetachSources = callbacks.isEmpty();
            if (shouldDetachSources) {
                playbackBuffer.clear();
                hasTargetFormat = false;
                lastInputSampleAtMs = 0L;
            }
        }

        if (shouldDetachSources) {
            inputSamplesInterceptor.detachCallback(id);
            playbackSamplesReadyCallbackAdapter.removeCallback(this);
        }
    }

    @Override
    public void onWebRtcAudioRecordSamplesReady(JavaAudioDeviceModule.AudioSamples audioSamples) {
        if (!isPcm16(audioSamples)) {
            dispatch(audioSamples);
            return;
        }

        byte[] inputData = audioSamples.getData();
        byte[] outputData;
        JavaAudioDeviceModule.AudioSamples mixedSamples;

        synchronized (this) {
            setTargetFormat(audioSamples);
            lastInputSampleAtMs = SystemClock.elapsedRealtime();
            outputData = playbackBuffer.take(inputData.length);
            mixedSamples = new JavaAudioDeviceModule.AudioSamples(
                    targetAudioFormat,
                    targetChannelCount,
                    targetSampleRate,
                    mixPcm16(inputData, outputData));
        }

        dispatch(mixedSamples);
    }

    @Override
    public void onWebRtcAudioTrackSamplesReady(JavaAudioDeviceModule.AudioSamples audioSamples) {
        if (!isPcm16(audioSamples)) {
            return;
        }

        JavaAudioDeviceModule.AudioSamples outputOnlySamples = null;

        synchronized (this) {
            if (!hasTargetFormat) {
                setTargetFormat(audioSamples);
            }

            byte[] normalizedData = normalizeToTargetFormat(audioSamples);
            if (normalizedData == null || normalizedData.length == 0) {
                return;
            }

            long nowMs = SystemClock.elapsedRealtime();
            if (lastInputSampleAtMs == 0L
                    || nowMs - lastInputSampleAtMs > OUTPUT_ONLY_FALLBACK_MS) {
                outputOnlySamples = new JavaAudioDeviceModule.AudioSamples(
                        targetAudioFormat,
                        targetChannelCount,
                        targetSampleRate,
                        normalizedData);
            } else {
                playbackBuffer.append(normalizedData);
                playbackBuffer.trimTo(maxPlaybackBufferBytes());
            }
        }

        if (outputOnlySamples != null) {
            dispatch(outputOnlySamples);
        }
    }

    private void setTargetFormat(JavaAudioDeviceModule.AudioSamples audioSamples) {
        boolean formatChanged = hasTargetFormat
                && (targetAudioFormat != audioSamples.getAudioFormat()
                || targetChannelCount != Math.max(1, audioSamples.getChannelCount())
                || targetSampleRate != Math.max(1, audioSamples.getSampleRate()));
        targetAudioFormat = audioSamples.getAudioFormat();
        targetChannelCount = Math.max(1, audioSamples.getChannelCount());
        targetSampleRate = Math.max(1, audioSamples.getSampleRate());
        hasTargetFormat = true;
        if (formatChanged) {
            playbackBuffer.clear();
        }
    }

    private boolean isPcm16(JavaAudioDeviceModule.AudioSamples audioSamples) {
        return audioSamples.getAudioFormat() == AudioFormat.ENCODING_PCM_16BIT;
    }

    private byte[] normalizeToTargetFormat(JavaAudioDeviceModule.AudioSamples audioSamples) {
        if (!hasTargetFormat || audioSamples.getSampleRate() != targetSampleRate) {
            return null;
        }

        int sourceChannelCount = Math.max(1, audioSamples.getChannelCount());
        byte[] sourceData = audioSamples.getData();
        if (sourceChannelCount == targetChannelCount) {
            return sourceData.clone();
        }

        int sourceFrameSize = sourceChannelCount * 2;
        int frameCount = sourceData.length / sourceFrameSize;
        byte[] targetData = new byte[frameCount * targetChannelCount * 2];

        for (int frame = 0; frame < frameCount; frame++) {
            for (int targetChannel = 0; targetChannel < targetChannelCount; targetChannel++) {
                short sample;
                if (targetChannelCount == 1) {
                    int sum = 0;
                    for (int sourceChannel = 0; sourceChannel < sourceChannelCount; sourceChannel++) {
                        sum += readPcm16(sourceData, (frame * sourceChannelCount + sourceChannel) * 2);
                    }
                    sample = (short) (sum / sourceChannelCount);
                } else if (sourceChannelCount == 1) {
                    sample = readPcm16(sourceData, frame * 2);
                } else {
                    int sourceChannel = Math.min(targetChannel, sourceChannelCount - 1);
                    sample = readPcm16(sourceData, (frame * sourceChannelCount + sourceChannel) * 2);
                }
                writePcm16(targetData, (frame * targetChannelCount + targetChannel) * 2, sample);
            }
        }

        return targetData;
    }

    private byte[] mixPcm16(byte[] primaryData, byte[] secondaryData) {
        byte[] mixedData = new byte[primaryData.length];
        for (int i = 0; i + 1 < primaryData.length; i += 2) {
            int mixedSample = readPcm16(primaryData, i) + readPcm16(secondaryData, i);
            if (mixedSample > Short.MAX_VALUE) {
                mixedSample = Short.MAX_VALUE;
            } else if (mixedSample < Short.MIN_VALUE) {
                mixedSample = Short.MIN_VALUE;
            }
            writePcm16(mixedData, i, (short) mixedSample);
        }
        if (primaryData.length % 2 == 1) {
            mixedData[primaryData.length - 1] = primaryData[primaryData.length - 1];
        }
        return mixedData;
    }

    private short readPcm16(byte[] data, int offset) {
        if (offset < 0 || offset + 1 >= data.length) {
            return 0;
        }
        return (short) ((data[offset] & 0xFF) | (data[offset + 1] << 8));
    }

    private void writePcm16(byte[] data, int offset, short sample) {
        data[offset] = (byte) (sample & 0xFF);
        data[offset + 1] = (byte) ((sample >> 8) & 0xFF);
    }

    private int maxPlaybackBufferBytes() {
        int bytesPerFrame = Math.max(1, targetChannelCount) * 2;
        long bytes = (long) targetSampleRate
                * bytesPerFrame
                * OUTPUT_BUFFER_LIMIT_MS
                / 1000L;
        return (int) Math.min(Integer.MAX_VALUE, Math.max(bytesPerFrame, bytes));
    }

    private void dispatch(JavaAudioDeviceModule.AudioSamples audioSamples) {
        JavaAudioDeviceModule.SamplesReadyCallback[] snapshot;
        synchronized (this) {
            snapshot = callbacks.values().toArray(
                    new JavaAudioDeviceModule.SamplesReadyCallback[0]);
        }
        for (JavaAudioDeviceModule.SamplesReadyCallback callback : snapshot) {
            callback.onWebRtcAudioRecordSamplesReady(audioSamples);
        }
    }

    private static class SampleBuffer {
        private final ArrayDeque<byte[]> chunks = new ArrayDeque<>();
        private int headOffset = 0;
        private int availableBytes = 0;

        void append(byte[] data) {
            if (data == null || data.length == 0) {
                return;
            }
            chunks.add(data.clone());
            availableBytes += data.length;
        }

        byte[] take(int byteCount) {
            byte[] data = new byte[byteCount];
            int writtenBytes = 0;
            while (writtenBytes < byteCount && !chunks.isEmpty()) {
                byte[] head = chunks.peek();
                int availableInHead = head.length - headOffset;
                int bytesToCopy = Math.min(byteCount - writtenBytes, availableInHead);
                System.arraycopy(head, headOffset, data, writtenBytes, bytesToCopy);
                writtenBytes += bytesToCopy;
                headOffset += bytesToCopy;
                availableBytes -= bytesToCopy;
                if (headOffset >= head.length) {
                    chunks.remove();
                    headOffset = 0;
                }
            }
            return data;
        }

        void trimTo(int maxBytes) {
            while (availableBytes > maxBytes && !chunks.isEmpty()) {
                byte[] head = chunks.remove();
                int removedBytes = head.length - headOffset;
                availableBytes -= removedBytes;
                headOffset = 0;
            }
        }

        void clear() {
            chunks.clear();
            headOffset = 0;
            availableBytes = 0;
        }
    }
}
