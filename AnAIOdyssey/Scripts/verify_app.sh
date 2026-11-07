#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=xcodebuild_env.sh
source "$(dirname "$0")/xcodebuild_env.sh"

xcodegen generate

echo "==> Building AnAIOdyssey (macOS)..."
xcodebuild build -scheme AnAIOdyssey -destination 'platform=macOS' -quiet $XCODEBUILD_EXTRA_FLAGS

echo "==> Unit tests (Steps 1-3, 7-9)..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet $XCODEBUILD_EXTRA_FLAGS \
  -only-testing:AnAIOdysseyCoreTests \
  -only-testing:AnAIOdysseyAITests \
  -only-testing:AnAIOdysseyMailTests \
  -only-testing:AnAIOdysseyIntegrationTests

echo "==> UI tests (Steps 4-6)..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet $XCODEBUILD_EXTRA_FLAGS \
  -only-testing:AnAIOdysseyUITests

echo ""
echo "Ready for manual verification. Run the app:"
echo "  open \"\$HOME/Library/Developer/Xcode/DerivedData/AnAIOdyssey-*/Build/Products/Debug/An AI Odyssey.app\""
echo "Or press Run in Xcode (AnAIOdyssey scheme, My Mac)."
echo ""
echo "Try in the app:"
echo "  1. Chats — New Chat, send a message (streams MLX response after model load)"
echo "  2. Documents — New Document, edit title/body, open a second tab, close one"
echo "  3. Notes — New Note, edit, convert to checklist, pin/archive"
echo "  4. Email (Mac) — inbox from Apple Mail (Full Disk Access) or fixture mode in tests"
echo "  5. Settings — iCloud storage mode, Local Models (download/delete, ¾-RAM limit)"
echo "  6. Email (Mac) — open message → Summarize / Draft Reply"
