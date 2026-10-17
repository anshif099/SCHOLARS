# Scholars

Distance-learning application for Scholars Academy.

On Windows, the Gradle launcher sets `-Djbr.java.io.use.nio=false` at JVM startup
to avoid JetBrains Runtime file-lock errors while Android Gradle Plugin appends
to generated CMake timing logs. The Windows launcher also disables daemon reuse
so a daemon started without that JVM workaround cannot cause the same lock again.
Use `flutter build appbundle` as usual. A fresh Gradle process adds some startup
time to Windows builds.

## Reliable live-class networking

Live classes use Firebase Realtime Database to exchange WebRTC offers, answers,
and ICE candidates. Each student connects only to the teacher. Firebase does
not relay the audio or video. The app includes STUN discovery and requests
short-lived Cloudflare TURN credentials when a live call starts. To enable it,
create a Cloudflare Realtime TURN key and store its key ID and API token as
Firebase Functions secrets:

```sh
firebase functions:secrets:set CLOUDFLARE_TURN_KEY_ID
firebase functions:secrets:set CLOUDFLARE_TURN_API_TOKEN
firebase deploy --only functions:getLiveClassIceServers
```

Enable Firebase Anonymous Authentication for live-call participants. Keep the
Cloudflare API token in Functions; never put it in Vercel or the Flutter build.
The app calls the deployed function's Cloud Run URL because the
`cloudfunctions.net` frontend is unreachable on some networks. If the function
is recreated in another project or region, set `WEBRTC_RELAY_CALLABLE_URL` to
its new Cloud Run URL using `--dart-define`. This endpoint still uses Firebase
callable authentication and keeps TURN secrets on the server.
The Vercel web build no longer needs TURN environment variables. Native builds
use the same callable function. Existing static TURN configuration remains
available for another relay provider:

```powershell
flutter build apk --release `
  --dart-define=WEBRTC_TURN_URLS="turn:relay.example.com:3478?transport=udp,turn:relay.example.com:3478?transport=tcp,turns:relay.example.com:5349" `
  --dart-define=WEBRTC_TURN_USERNAME="temporary-username" `
  --dart-define=WEBRTC_TURN_CREDENTIAL="temporary-password"
```

Do not commit TURN credentials to this repository. Without a working relay,
calls on carrier networks can remain stuck on Connecting.

Recording uploads require Firebase Storage on the active project, Anonymous
Authentication enabled, and the deployed `storage.rules` in this repository.
The stored `upload_error` on a failed recording contains the Storage error code.
For a device check, test teacher and student on separate mobile networks,
then repeat with two students, a student rejoin, and a teacher end. Finish a
teacher recording and verify its `recorded_classes` entry reaches `ready`
with a working `video_url`.

To check saved web recordings in Chrome on Windows, run
`powershell -ExecutionPolicy Bypass -File tool/test_recording_web.ps1`.
The test records a generated tone and video, decodes the saved file, checks audio
at the beginning, middle, and end, and seeks to a video frame near the end.
The runner temporarily enables generated audio in headless Chrome and works
around Flutter's Windows CanvasKit test-server path issue. Android microphone
capture still requires a connected device for verification.

The native Android recorder has a codec test runner for a connected device or
emulator. It generates video and a tone, simulates a gap in audio callbacks and
delayed audio startup, changing PCM formats, and verifies video-only capture plus
decoded video frames at both ends. It also checks that finalization rejects a
recording without an audio track. From the project root in PowerShell:

```powershell
Push-Location android
.\gradlew.bat :flutter_webrtc:assembleDebugAndroidTest '-PrecordingTestRunner=com.cloudwebrtc.webrtc.record.RecordingMediaTestRunner'
Pop-Location
adb install -r -t build/flutter_webrtc/outputs/apk/androidTest/debug/flutter_webrtc-debug-androidTest.apk
adb shell am instrument -w com.cloudwebrtc.webrtc.test/com.cloudwebrtc.webrtc.record.RecordingMediaTestRunner
```

This test exercises the Android encoder and MP4 muxer; it does not use a real
microphone or test an existing uploaded recording.

Android recording keeps a local audio connection active during capture and
normalizes AAC input to mono 48 kHz PCM16. A failed AAC setup is released before
retrying. A recording without saved audio reports an error and retains the local
video instead of uploading it as a successful class recording. This check detects
missing audio packets; it does not detect a track containing only silence.
Opening recorded media restores Android's normal media audio mode after a call.
