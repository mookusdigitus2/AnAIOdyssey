#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

echo "==> Building AnAIOdyssey (macOS)..."
xcodebuild build -scheme AnAIOdyssey -destination 'platform=macOS' -quiet

APP="$(find ~/Library/Developer/Xcode/DerivedData/AnAIOdyssey-*/Build/Products/Debug -name 'An AI Odyssey.app' -maxdepth 1 2>/dev/null | head -1)"
if [[ -z "$APP" ]]; then
  echo "ERROR: An AI Odyssey.app not found in DerivedData"
  exit 1
fi

echo "==> Launching $APP..."
open -a "$APP" --args -AnAIOdysseyLaunchSmokeTest
sleep 2
if pgrep -x "An AI Odyssey" >/dev/null; then
  echo "PASS: An AI Odyssey process running"
  pkill -x "An AI Odyssey" || true
else
  echo "ERROR: An AI Odyssey did not stay running"
  exit 1
fi

echo "==> Unit tests..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyCoreTests \
  -only-testing:AnAIOdysseyAITests \
  -only-testing:AnAIOdysseyMailTests \
  -only-testing:AnAIOdysseyIntegrationTests

echo "==> iPad build..."
xcodebuild build -scheme AnAIOdyssey -destination 'platform=iOS Simulator,name=iPad (A16),OS=26.5' -quiet

echo "All Step 1 automated checks passed."
