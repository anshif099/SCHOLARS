package com.cloudwebrtc.webrtc.record;

import android.media.AudioFormat;
import org.webrtc.audio.JavaAudioDeviceModule.AudioSamples;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Keeps the AAC input format stable when microphone and playback formats differ. */
final class RecordingAudioFormat {
    static final int SAMPLE_RATE = 48000;
    static final int CHANNELS = 1;

    static AudioSamples normalize(AudioSamples source) {
        int channels = source.getChannelCount();
        int rate = source.getSampleRate();
        int format = source.getAudioFormat();
        if (channels <= 0 || rate <= 0) throw new IllegalArgumentException("Invalid PCM format");
        if (format == AudioFormat.ENCODING_PCM_16BIT && channels == CHANNELS && rate == SAMPLE_RATE) {
            return source;
        }
        int bytesPerSample;
        if (format == AudioFormat.ENCODING_PCM_FLOAT) bytesPerSample = 4;
        else if (format == AudioFormat.ENCODING_PCM_16BIT) bytesPerSample = 2;
        else if (format == AudioFormat.ENCODING_PCM_8BIT) bytesPerSample = 1;
        else throw new IllegalArgumentException("Unsupported recording PCM format: " + format);
        ByteBuffer input = ByteBuffer.wrap(source.getData()).order(ByteOrder.LITTLE_ENDIAN);
        int inputFrames = input.remaining() / (channels * bytesPerSample);
        int outputFrames = (int) Math.round(inputFrames * (double) SAMPLE_RATE / rate);
        ByteBuffer output = ByteBuffer.allocate(outputFrames * 2).order(ByteOrder.LITTLE_ENDIAN);
        for (int frame = 0; frame < outputFrames && inputFrames > 0; frame++) {
            double position = frame * (double) rate / SAMPLE_RATE;
            int left = Math.min(inputFrames - 1, (int) position);
            int right = Math.min(inputFrames - 1, left + 1);
            double fraction = Math.min(1, position - left);
            double value = 0;
            for (int channel = 0; channel < channels; channel++) {
                double a = sample(input, left * channels + channel, format);
                double b = sample(input, right * channels + channel, format);
                value += a + (b - a) * fraction;
            }
            value /= channels;
            if (Double.isNaN(value) || Double.isInfinite(value)) value = 0;
            output.putShort((short) Math.round(Math.max(-1, Math.min(1, value)) * 32767));
        }
        return new AudioSamples(AudioFormat.ENCODING_PCM_16BIT, CHANNELS, SAMPLE_RATE, output.array());
    }

    private static double sample(ByteBuffer input, int index, int format) {
        if (format == AudioFormat.ENCODING_PCM_FLOAT) return input.getFloat(index * 4);
        if (format == AudioFormat.ENCODING_PCM_8BIT) return ((input.get(index) & 255) - 128) / 128.0;
        return input.getShort(index * 2) / 32768.0;
    }
}
