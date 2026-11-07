#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

echo "==> Step 2: Model unit tests..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyCoreTests/ModelTests \
  -only-testing:AnAIOdysseyCoreTests/AnAIOdysseyCoreTests

echo "Step 2 automated checks passed."
