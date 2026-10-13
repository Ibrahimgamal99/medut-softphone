#!/usr/bin/env bash
# Build the Google Play App Bundle, signed with the upload key.
#   scripts/build-release.sh          build/app/outputs/bundle/release/app-release.aab
#   scripts/build-release.sh --apk    also one APK per ABI, for direct installs
#
# Dart debug info goes to symbols/<version>/ (git-ignored). Keep that folder
# for every release you ship: it is the only way to read that build's Dart
# stack traces (flutter symbolize -i <trace> -d symbols/<version>/<file>).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ ! -f android/key.properties ]; then
  echo "ERROR: android/key.properties is missing, so the build would be signed" \
       "with the debug key and Google Play would reject it. See docs/google-play.md." >&2
  exit 1
fi

version="$(awk '/^version:/ {print $2}' pubspec.yaml)"
symbols="symbols/${version}"

flutter build appbundle --release --split-debug-info="${symbols}"
if [ "${1:-}" = "--apk" ]; then
  flutter build apk --release --split-per-abi --split-debug-info="${symbols}"
fi
echo "Debug symbols: ${symbols}"
