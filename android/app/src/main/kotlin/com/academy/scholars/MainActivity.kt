package com.academy.scholars

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val AUDIO_OUTPUT_CHANNEL = "com.academy.scholars/audio_output"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createLiveClassNotificationChannel()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.academy.scholars/recording_upload").setMethodCallHandler { call, result ->
            try {
                val intent = Intent(this, RecordingUploadService::class.java)
                when (call.method) {
                    "start" -> { startForegroundService(intent); result.success(null) }
                    "stop" -> { stopService(intent); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("UPLOAD_SERVICE_ERROR", error.message, null)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUDIO_OUTPUT_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareMediaPlayback" -> {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            audioManager.clearCommunicationDevice()
                        } else {
                            @Suppress("DEPRECATION")
                            audioManager.stopBluetoothSco()
                            @Suppress("DEPRECATION")
                            audioManager.isSpeakerphoneOn = false
                        }
                        audioManager.mode = AudioManager.MODE_NORMAL
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("AUDIO_OUTPUT_ERROR", "Unable to restore media audio.", error.message)
                    }
                }
                "maximizeSpeakerVolume" -> {
                    try {
                        maximizeSpeakerVolume()
                        result.success(null)
                    } catch (error: Exception) {
                        result.error(
                            "AUDIO_OUTPUT_ERROR",
                            "Unable to maximize the speaker volume.",
                            error.message
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun maximizeSpeakerVolume() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = audioManager.availableCommunicationDevices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            if (speaker != null) {
                audioManager.setCommunicationDevice(speaker)
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = true
        }

        if (!audioManager.isVolumeFixed) {
            audioManager.setStreamVolume(
                AudioManager.STREAM_VOICE_CALL,
                audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL),
                0
            )
            audioManager.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                0
            )
        }
    }

    private fun createLiveClassNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            "live_class_calls",
            "Live Class Calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming live class call notifications"
            enableVibration(true)
            setShowBadge(true)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }
}
