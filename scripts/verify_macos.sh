#!/bin/bash
# Real Swift and Xcode checks. No signing credentials required.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'This check requires macOS and Xcode. Run ios-verify in Codemagic.' >&2
  exit 1
fi
mkdir -p build
xcodebuild -version | tee build/xcode-version.log
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
python3 - "$SDK_VERSION" <<'PY'
import sys
version = tuple(int(x) for x in sys.argv[1].split('.')[:2])
if version < (26, 2):
    raise SystemExit('Requires an iOS 26.2+ SDK for far-field APIs; deployment remains iOS 26.0.')
PY
swift test 2>&1 | tee build/core-tests.log
python3 scripts/verify_project.py
plutil -lint Resources/Info.plist Resources/PrivacyInfo.xcprivacy AirPodsTranslator.xcodeproj/project.pbxproj
xcrun simctl list devices available --json > build/simulators.json
SIMULATOR_ID="$(python3 - <<'PY'
import json
import re
from pathlib import Path
devices = json.loads(Path('build/simulators.json').read_text())['devices']
candidates = []
for runtime, entries in devices.items():
    match = re.search(r'iOS-(\d+)-(\d+)', runtime)
    if not match or int(match[1]) < 26:
        continue
    for device in entries:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            candidates.append(((int(match[1]), int(match[2])), device['udid']))
if not candidates:
    raise SystemExit('Install an available iOS 26+ iPhone simulator runtime on this Xcode image.')
print(sorted(candidates, reverse=True)[0][1])
PY
)"
# Use a unique result path so rerunning this command never deletes earlier evidence.
RESULT_PATH="build/Tests-$(date -u +%Y%m%dT%H%M%SZ).xcresult"
xcodebuild test \
  -project AirPodsTranslator.xcodeproj \
  -scheme AirPodsTranslator \
  -configuration Debug \
  -parallel-testing-enabled NO \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "$RESULT_PATH" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/ios-tests.log
# XCTest can use/stop a simulator clone. Explicitly boot and install onto the
# selected device before capturing actual UI; no microphone or AirPods exercise.
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
SIM_APP='build/DerivedData/Build/Products/Debug-iphonesimulator/AirPodsTranslator.app'
SIM_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SIM_APP/Info.plist")"
xcrun simctl install "$SIMULATOR_ID" "$SIM_APP"
xcrun simctl launch "$SIMULATOR_ID" "$SIM_BUNDLE_ID" > build/simulator-launch.log 2>&1
sleep 2
xcrun simctl io "$SIMULATOR_ID" screenshot build/home-simulator.png
# Also compile the release/device architecture before a signing workflow.
xcodebuild build \
  -project AirPodsTranslator.xcodeproj \
  -scheme AirPodsTranslator \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/ios-release.log
