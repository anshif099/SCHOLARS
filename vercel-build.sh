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
flutter build web --release

echo "=== Build Completed Successfully ==="
