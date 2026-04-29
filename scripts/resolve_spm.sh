#!/usr/bin/env bash
# Re-resolve Swift packages when Xcode shows all dependencies in red
# (common causes: disk full, interrupted checkout, corrupt DerivedData checkouts).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Removing Sphere DerivedData folders (only names starting with Sphere-)…"
rm -rf "${HOME}/Library/Developer/Xcode/DerivedData/Sphere-"*

CLONE_DIR="${TMPDIR:-/tmp}/SphereSPMCheckouts"
mkdir -p "$CLONE_DIR"

echo "Resolving packages with clone directory: $CLONE_DIR"
xcodebuild \
  -project Sphere.xcodeproj \
  -scheme Sphere \
  -resolvePackageDependencies \
  -clonedSourcePackagesDirPath "$CLONE_DIR"

echo "Done. Open Sphere.xcodeproj in Xcode, then Product → Clean Build Folder and build."
