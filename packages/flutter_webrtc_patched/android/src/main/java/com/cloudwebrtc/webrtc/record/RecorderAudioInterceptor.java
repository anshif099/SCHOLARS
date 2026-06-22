package com.cloudwebrtc.webrtc.record;

import org.webrtc.audio.JavaAudioDeviceModule;

public interface RecorderAudioInterceptor {
    void attachCallback(Integer id, JavaAudioDeviceModule.SamplesReadyCallback callback) throws Exception;

    void detachCallback(Integer id);
}
