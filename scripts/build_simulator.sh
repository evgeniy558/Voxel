#!/usr/bin/env bash
# Одна команда: починить SwiftPM при необходимости + собрать схему Sphere для симулятора.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$(dirname "$0")/resolve_spm.sh"
xcodebuild -project Sphere.xcodeproj -scheme Sphere -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -quiet build
echo "→ Сборка Sphere (Simulator) OK."
