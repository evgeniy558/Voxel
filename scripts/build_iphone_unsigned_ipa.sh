#!/usr/bin/env bash
# Device (iphoneos) IPA without code signing.
# Use with Sideloadly / iOS App Signer: import IPA → sign with your Apple ID.
#
# DEBUG_INFORMATION_FORMAT=dwarf — без отдельного dSYM (меньше места; иначе при полном диске падает dsymutil).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# При нехватке места в каталоге проекта можно задать:
#   export SPHERE_IPA_DERIVED=/tmp/SphereIPA-Derived
DERIVED="${SPHERE_IPA_DERIVED:-${ROOT}/build/DerivedDeviceUnsigned}"
OUT_IPA="${SPHERE_IPA_OUT:-${ROOT}/build/Sphere-iphoneos-unsigned.ipa}"

rm -rf "$DERIVED" "${ROOT}/build/ipa_device_staging" 2>/dev/null || true

xcodebuild -project Sphere.xcodeproj -scheme Sphere -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  DEBUG_INFORMATION_FORMAT=dwarf

STAGE="${ROOT}/build/ipa_device_staging"
mkdir -p "$STAGE/Payload"
cp -R "${DERIVED}/Build/Products/Release-iphoneos/Sphere.app" "$STAGE/Payload/"
( cd "$STAGE" && zip -qry "$OUT_IPA" Payload )
echo "OK: $OUT_IPA"
ls -lh "$OUT_IPA"
