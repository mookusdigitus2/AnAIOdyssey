#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== Step 12: Memory and embeddings =="

xcodegen generate

xcodebuild build -scheme AnAIOdyssey -destination 'platform=macOS' -quiet

xcodebuild test -scheme AnAIOdyssey -destination 'platform=macOS' \
  -only-testing:AnAIOdysseyCoreTests/MemoryServiceTests \
  -only-testing:AnAIOdysseyIntegrationTests/MemoryPersistenceIntegrationTests \
  -only-testing:AnAIOdysseyAITests/EmbeddingServiceTests \
  -quiet

echo "Step 12 gate passed."
