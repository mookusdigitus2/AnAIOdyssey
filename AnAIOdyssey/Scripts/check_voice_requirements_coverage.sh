#!/bin/sh
# Fails when a requirement in docs/VOICE_MODE_REQUIREMENTS.md has no automated
# test tagged with its ID in AnAIOdysseyAITests (a `/// ... REQ-07` line right
# above `func test...`, or REQ07 in the test name). Same rule as
# VoiceRequirementsCoverageTests. Run from anywhere.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
doc="$here/docs/VOICE_MODE_REQUIREMENTS.md"
tests="$here/AnAIOdysseyAITests"

required=$(grep -Eo '^[0-9]+\. \*\*REQ-[0-9]{2}' "$doc" | grep -Eo 'REQ-[0-9]{2}')
tagged=$(awk '
  /^[[:space:]]*\/\/\// { doc = doc " " $0; next }
  /^[[:space:]]*func test/ { print doc " " $0; doc = ""; next }
  { doc = "" }
' "$tests"/*.swift | grep -Eo 'REQ-?[0-9]{2}' | sed -E 's/REQ-?/REQ-/' | sort -u)

missing=""
for id in $required; do
  echo "$tagged" | grep -qx "$id" || missing="$missing $id"
done
count=$(echo "$required" | wc -l | tr -d ' ')
if [ -n "$missing" ]; then
  echo "error: voice requirements with no tagged test:$missing" >&2
  exit 1
fi
echo "voice requirements coverage: $count/$count requirements have tagged tests"
