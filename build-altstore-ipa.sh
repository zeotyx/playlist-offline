#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
flutter pub get
flutter build ios --release --no-codesign \
  --dart-define="SPOTIFY_CLIENT_ID=${SPOTIFY_CLIENT_ID:-}" \
  --dart-define="JAMENDO_CLIENT_ID=${JAMENDO_CLIENT_ID:-}"

staging="$(mktemp -d)"
trap 'find "$staging" -depth -delete' EXIT
mkdir "$staging/Payload"
ditto build/ios/iphoneos/Runner.app "$staging/Payload/Runner.app"
ditto -c -k --keepParent "$staging/Payload" "$PWD/build/PlaylistOffline.ipa"
