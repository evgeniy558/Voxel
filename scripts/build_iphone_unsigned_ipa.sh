#!/usr/bin/env bash
# Device (iphoneos) IPA without code signing.
# Use with Sideloadly / iOS App Signer: import IPA → sign with your Apple ID.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DERIVED="${ROOT}/build/DerivedDeviceUnsigned"
OUT_IPA="${ROOT}/build/Sphere-iphoneos-unsigned.ipa"
rm -rf "$DERIVED" "${ROOT}/build/ipa_device_staging" 2>/dev/null || true
xcodebuild -project Sphere.xcodeproj -scheme Sphere -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
STAGE="${ROOT}/build/ipa_device_staging"
mkdir -p "$STAGE/Payload"
cp -R "${DERIVED}/Build/Products/Release-iphoneos/Sphere.app" "$STAGE/Payload/"
( cd "$STAGE" && zip -qry "$OUT_IPA" Payload )
echo "OK: $OUT_IPA"
ls -lh "$OUT_IPA"
