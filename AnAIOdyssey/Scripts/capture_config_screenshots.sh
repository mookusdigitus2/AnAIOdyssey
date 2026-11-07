#!/usr/bin/env bash
# Capture AI and voice Settings screenshots on the canonical Mac checkout.
#
# Expected checkout: ~/Developement/AnAIOdyssey
# (the repository root that contains AnAIOdyssey/AnAIOdyssey.xcodeproj).
# Run: ~/Developement/AnAIOdyssey/AnAIOdyssey/Scripts/capture_config_screenshots.sh
# This script does not clone and does not install to a physical device.
#
# It uninstalls the app from the chosen simulator before the test so the
# capture starts from an empty container. Set SIMULATOR_ID to pick a
# simulator other than the first available iPhone on iOS 27.
#
# Outputs, gitignored under AnAIOdyssey/build/:
#   config-screenshots/ai-models.png
#   config-screenshots/ai-connection.png
#   config-screenshots/voice-settings.png
#   config-screenshots/voice-list.png
#   ConfigShots.xcresult
#   config-screenshots-xcodebuild.log
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This capture runs on macOS with Xcode. It cannot run on Linux." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="$REPO_ROOT/AnAIOdyssey/AnAIOdyssey.xcodeproj"
OUT_DIR="$REPO_ROOT/AnAIOdyssey/build/config-screenshots"
DERIVED="$REPO_ROOT/AnAIOdyssey/build/ConfigShotsDerived"
RESULT="$REPO_ROOT/AnAIOdyssey/build/ConfigShots.xcresult"
LOG="$REPO_ROOT/AnAIOdyssey/build/config-screenshots-xcodebuild.log"

if [[ ! -d "$PROJECT" ]]; then
  echo "Expected the Xcode project at $PROJECT" >&2
  echo "Run this from the checkout at ~/Developement/AnAIOdyssey." >&2
  exit 1
fi
echo "Repo root: $REPO_ROOT"

PREFIX="com.example"
LOCAL_XCCONFIG="$REPO_ROOT/AnAIOdyssey/Config/Local.xcconfig"
if [[ -f "$LOCAL_XCCONFIG" ]]; then
  PARSED="$(awk -F= '/^BUNDLE_ID_PREFIX[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$LOCAL_XCCONFIG")"
  if [[ -n "${PARSED}" ]]; then
    PREFIX="$PARSED"
  fi
fi
BUNDLE_ID="${PREFIX}.anaiodyssey"

if [[ -n "${SIMULATOR_ID:-}" ]]; then
  DEVICE_ID="$SIMULATOR_ID"
  echo "Using SIMULATOR_ID=$DEVICE_ID"
else
  DEVICE_ID="$(
    xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
best = None
for runtime, devices in data.get("devices", {}).items():
    if "iOS-" not in runtime:
        continue
    version = runtime.split("iOS-")[-1].replace("-", ".")
    if not version.startswith("27."):
        continue
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        if "iPhone" not in name:
            continue
        rank = (0 if ("Pro" in name and "Max" not in name) else 1, name)
        candidate = (rank, device["udid"], name, version)
        if best is None or candidate[0] < best[0]:
            best = candidate
if best is None:
    print("No available iPhone simulator on an iOS 27 runtime.", file=sys.stderr)
    sys.exit(2)
print("%s\t%s\t%s" % (best[1], best[2], best[3]))
'
  )"
  DEVICE_NAME="${DEVICE_ID#*$'\t'}"
  DEVICE_ID="${DEVICE_ID%%$'\t'*}"
  echo "Selected simulator: $DEVICE_NAME ($DEVICE_ID)"
fi

mkdir -p "$OUT_DIR"
rm -rf "$RESULT"
rm -f "$OUT_DIR"/*.png

echo "Uninstalling $BUNDLE_ID from that simulator so the capture is empty."
xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" || true

cd "$REPO_ROOT"
xcodebuild test \
  -project "$PROJECT" \
  -scheme AnAIOdyssey \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -only-testing:AnAIOdysseyUITests/ConfigScreenshotUITests \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  TEST_RUNNER_CONFIG_SHOTS_DIR="$OUT_DIR" \
  | tee "$LOG"

echo
echo "PNGs:"
ls -la "$OUT_DIR"/*.png
echo "Review these files before copying them into docs/screenshots."
echo "Do not publish a shot that shows a key, email, team id, or device name."
