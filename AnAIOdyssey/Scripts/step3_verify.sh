#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

echo "==> Step 3: Repository unit tests..."
xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' -quiet \
  -only-testing:AnAIOdysseyCoreTests/RepositoryTests

echo "Step 3 automated checks passed."
