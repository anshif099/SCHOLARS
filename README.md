# Scholars

Distance-learning application for Scholars Academy.

## Reliable live-class networking

Live classes use Firebase Realtime Database to exchange WebRTC offers, answers,
and ICE candidates. Each student connects only to the teacher. Firebase does
not relay the audio or video. The app always includes STUN discovery. Production builds must also provide
a TURN relay so teacher/student calls work when the two Android devices are on
different mobile or Wi-Fi networks:

```powershell
flutter build apk --release `
  --dart-define=WEBRTC_TURN_URLS="turn:relay.example.com:3478?transport=udp,turn:relay.example.com:3478?transport=tcp,turns:relay.example.com:5349" `
  --dart-define=WEBRTC_TURN_USERNAME="temporary-username" `
  --dart-define=WEBRTC_TURN_CREDENTIAL="temporary-password"
```

Use short-lived TURN credentials from your relay provider in CI/release builds;
do not commit credentials to this repository. If any of the three values are
missing, the app falls back to STUN-only connectivity, which can remain stuck
on Connecting on carrier networks. Check the actual release build's dart
defines when investigating this symptom.

Recording uploads require Firebase Storage on the active project, Anonymous
Authentication enabled, and the deployed `storage.rules` in this repository.
The stored `upload_error` on a failed recording contains the Storage error code.
For a device check, test teacher and student on separate mobile networks,
then repeat with two students, a student rejoin, and a teacher end. Finish a
teacher recording and verify its `recorded_classes` entry reaches `ready`
with a working `video_url`.
