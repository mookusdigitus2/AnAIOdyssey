#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

echo "==> Building AnAIOdyssey (macOS)..."
xcodebuild build -scheme AnAIOdyssey -destination 'platform=macOS' -quiet

echo "==> Step 7: CloudKit configuration tests..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyCoreTests/CloudKitTests

echo "==> Steps 8-9: LLM service tests (mock; MLX device tests skipped unless MLX_DEVICE_TESTS=1)..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyAITests/LLMServiceTests

echo "==> UI regression (Steps 4-6)..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyUITests

echo ""
echo "Steps 7-9 automated checks passed."
echo ""
echo "Manual verification:"
echo "  1. Settings → Storage shows iCloud (CloudKit) or Local"
echo "  2. Settings → Local Models → Download Llama 3.2 1B (no model is downloaded by default)"
echo "  3. Chats → New Chat → send message → streamed MLX response"
echo "  4. Optional: second device signed into same iCloud to confirm sync"
echo ""
echo "Optional MLX device integration test:"
echo "  MLX_DEVICE_TESTS=1 xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' \\"
echo "    -only-testing:AnAIOdysseyAITests/LLMServiceTests/testMLXLoadAndGenerate"
