package com.cloudwebrtc.webrtc.record;

import android.annotation.SuppressLint;
import android.os.SystemClock;

import org.webrtc.audio.JavaAudioDeviceModule.SamplesReadyCallback;
import org.webrtc.audio.JavaAudioDeviceModule.AudioSamples;

import java.util.HashMap;

/** JavaAudioDeviceModule allows attaching samples callback only on building
 *  We don't want to instantiate VideoFileRenderer and codecs at this step
 *  It's simple dummy class, it does nothing until samples are necessary */
@SuppressWarnings("WeakerAccess")
public class AudioSamplesInterceptor implements SamplesReadyCallback, RecorderAudioInterceptor {
    private static final long FALLBACK_SUPPRESSION_MS = 250L;

    @SuppressLint("UseSparseArrays")
    protected final HashMap<Integer, SamplesReadyCallback> callbacks = new HashMap<>();
    private volatile long lastNativeSampleAtMs = 0L;

    public interface NativeSampleListener {
        void onNativeSampleReceived();
    }

    private NativeSampleListener nativeSampleListener;

    public void setNativeSampleListener(NativeSampleListener listener) {
        this.nativeSampleListener = listener;
    }

    public void onFallbackAudioRecordSamplesReady(AudioSamples audioSamples) {
        long lastNativeSample = lastNativeSampleAtMs;
        if (lastNativeSample != 0L
                && SystemClock.elapsedRealtime() - lastNativeSample <= FALLBACK_SUPPRESSION_MS) {
            return;
        }
        synchronized (callbacks) {
            for (SamplesReadyCallback callback : callbacks.values()) {
                callback.onWebRtcAudioRecordSamplesReady(audioSamples);
            }
        }
    }

    @Override
    public void onWebRtcAudioRecordSamplesReady(AudioSamples audioSamples) {
        lastNativeSampleAtMs = SystemClock.elapsedRealtime();
        if (nativeSampleListener != null) {
            try {
                nativeSampleListener.onNativeSampleReceived();
            } catch (Exception e) {
                // ignore
            }
        }
        synchronized (callbacks) {
            for (SamplesReadyCallback callback : callbacks.values()) {
                callback.onWebRtcAudioRecordSamplesReady(audioSamples);
            }
        }
    }

    @Override
    public void attachCallback(Integer id, SamplesReadyCallback callback) throws Exception {
        synchronized (callbacks) {
            callbacks.put(id, callback);
        }
    }

    @Override
    public void detachCallback(Integer id) {
        synchronized (callbacks) {
            callbacks.remove(id);
        }
    }

}
