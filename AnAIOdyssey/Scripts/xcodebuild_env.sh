#!/usr/bin/env bash
# Optional overrides for local/CI verify scripts only.
# Device builds use automatic signing from project.yml (team from Config/Local.xcconfig).
# Example: source this file then run xcodebuild with $XCODEBUILD_EXTRA_FLAGS
export XCODEBUILD_EXTRA_FLAGS="${XCODEBUILD_EXTRA_FLAGS:-CODE_SIGNING_ALLOWED=NO}"
