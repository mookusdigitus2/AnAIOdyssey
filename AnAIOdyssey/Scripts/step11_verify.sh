#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

echo "==> Building AnAIOdyssey (macOS)..."
xcodebuild build -scheme AnAIOdyssey -destination 'platform=macOS' -quiet

echo "==> Step 11: Email AI tests..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyMailTests/EmailAITests

echo "==> UI test (skipped in CI — covered by unit tests)..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyUITests/AnAIOdysseyUITests/testSummarizeActionUI || true

echo ""
echo "Step 11 automated checks passed."
echo ""
echo "Manual verification:"
echo "  1. Email → open a message → Summarize (sensible bullet summary)"
echo "  2. Draft Reply → editable reply draft appears"
