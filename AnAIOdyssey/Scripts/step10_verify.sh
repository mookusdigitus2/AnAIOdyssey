#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

echo "==> Building AnAIOdyssey (macOS)..."
xcodebuild build -scheme AnAIOdyssey -destination 'platform=macOS' -quiet

echo "==> Step 10: Mail parser + fixture database tests..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyMailTests

echo "==> UI regression including fixture inbox..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyUITests

echo ""
echo "Step 10 automated checks passed."
echo ""
echo "Manual verification (Mac with Mail.app):"
echo "  1. System Settings → Privacy → Full Disk Access → add An AI Odyssey"
echo "  2. Email section → your real mailboxes and inbox messages"
echo "  3. Open a message → body text displays correctly"
