# Cloudflare Realtime SFU activation

The Flutter and Firebase Functions integration is already implemented. Until
the two Firebase secrets below exist and the callable function is deployed,
the app safely falls back to the teacher-to-student WebRTC transport.

## 1. Create the Realtime application

In the Cloudflare dashboard, open **Realtime > SFU > Create application** and
copy its **App ID** and **App Secret**.

## 2. Store credentials in Firebase Secret Manager

Run these commands from the project root. Each command prompts for the value;
do not put either value in source control.

```powershell
npx firebase-tools functions:secrets:set CLOUDFLARE_REALTIME_APP_ID
npx firebase-tools functions:secrets:set CLOUDFLARE_REALTIME_APP_SECRET
```

## 3. Deploy the backend

```powershell
npx firebase-tools deploy --only functions:cloudflareSfu
```

Then deploy the updated web build and distribute the updated Android app. No
Cloudflare credential or compile-time flag belongs in Flutter or Vercel.

## Resulting classroom topology

- Each device publishes one audio track and one video track to Cloudflare.
- The teacher subscribes to every active student's tracks.
- A student subscribes to the teacher and up to 11 other active participants.
- Firebase continues to provide authentication, presence, classroom state,
  whiteboard state, notifications, and recording metadata.
- If Cloudflare is unavailable during startup, the existing teacher/student
  fallback remains available, but student-to-student media is disabled.
