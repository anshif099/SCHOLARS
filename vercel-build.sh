#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "=== Installing Flutter SDK ==="
if [ ! -d "flutter" ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1
else
  cd flutter
  git pull
  cd ..
fi

# Add Flutter to the path
export PATH="$PATH:`pwd`/flutter/bin"

echo "=== Enabling Web Support ==="
flutter config --enable-web

echo "=== Building Flutter Web Project ==="
if [ -z "${WEBRTC_TURN_URLS:-}" ] || [ -z "${WEBRTC_TURN_USERNAME:-}" ] || [ -z "${WEBRTC_TURN_CREDENTIAL:-}" ]; then
  echo "=== ERROR: Live video requires WEBRTC_TURN_URLS, WEBRTC_TURN_USERNAME, and WEBRTC_TURN_CREDENTIAL in Vercel Production environment variables ===" >&2
  exit 1
fi

if [[ ! "${WEBRTC_TURN_URLS}" =~ ^turns?: ]]; then
  echo "=== ERROR: WEBRTC_TURN_URLS must begin with turn: or turns: ===" >&2
  exit 1
fi

TURN_ARGS=(
  "--dart-define=WEBRTC_TURN_URLS=${WEBRTC_TURN_URLS}"
  "--dart-define=WEBRTC_TURN_USERNAME=${WEBRTC_TURN_USERNAME}"
  "--dart-define=WEBRTC_TURN_CREDENTIAL=${WEBRTC_TURN_CREDENTIAL}"
)
echo "=== TURN relay configuration enabled ==="

flutter build web --release "${TURN_ARGS[@]}"

echo "=== Build Completed Successfully ==="
