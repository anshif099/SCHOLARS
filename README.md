# Scholars

Distance-learning application for Scholars Academy.

## Reliable live-class networking

The app always includes STUN discovery. Production builds should also provide
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
missing, the app safely falls back to STUN-only connectivity.
