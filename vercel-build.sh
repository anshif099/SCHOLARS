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
TURN_ARGS=()
if [ -n "${WEBRTC_TURN_URLS:-}" ] && [ -n "${WEBRTC_TURN_USERNAME:-}" ] && [ -n "${WEBRTC_TURN_CREDENTIAL:-}" ]; then
  TURN_ARGS+=("--dart-define=WEBRTC_TURN_URLS=${WEBRTC_TURN_URLS}")
  TURN_ARGS+=("--dart-define=WEBRTC_TURN_USERNAME=${WEBRTC_TURN_USERNAME}")
  TURN_ARGS+=("--dart-define=WEBRTC_TURN_CREDENTIAL=${WEBRTC_TURN_CREDENTIAL}")
  echo "=== TURN relay configuration enabled ==="
else
  echo "=== WARNING: TURN relay configuration is incomplete; using STUN only ==="
fi

flutter build web --release "${TURN_ARGS[@]}"

echo "=== Build Completed Successfully ==="
