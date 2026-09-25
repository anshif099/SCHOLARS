# Scholars

Distance-learning application for Scholars Academy.

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
