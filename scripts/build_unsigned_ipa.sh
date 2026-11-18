#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ios/ipa
python3 scripts/generate_project.py \
  --bundle-id "${BUNDLE_ID:-com.example.airpodstranslator}" \
  --build-number "${BUILD_NUMBER:-1}"
xcodebuild archive \
  -project AirPodsTranslator.xcodeproj \
  -scheme AirPodsTranslator \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/UnsignedDerivedData \
  -archivePath build/ios/AirPodsTranslator-unsigned.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  2>&1 | tee build/unsigned-archive.log
python3 scripts/package_unsigned_ipa.py \
  build/ios/AirPodsTranslator-unsigned.xcarchive/Products/Applications/AirPodsTranslator.app \
  build/ios/ipa/AirLiveTranslate-unsigned.ipa
