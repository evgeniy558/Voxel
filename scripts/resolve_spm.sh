#!/usr/bin/env bash
# Восстановление SwiftPM после «Missing package product» / красных пакетов в Xcode.
# Частые причины: переполненный диск, оборванный git checkout, гонка при первом clone пакета Chat.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Закрой Xcode полностью (⌘Q), иначе он снова заблокирует или перезапишет DerivedData."
echo "→ Удаляю ~/Library/Developer/Xcode/DerivedData/Sphere-* …"
rm -rf "${HOME}/Library/Developer/Xcode/DerivedData/Sphere-"*

XCB=(
  xcodebuild
  -project Sphere.xcodeproj
  -scheme Sphere
  -resolvePackageDependencies
)

if [[ -n "${SPHERE_SPM_CLONE_DIR:-}" ]]; then
  mkdir -p "$SPHERE_SPM_CLONE_DIR"
  XCB+=(-clonedSourcePackagesDirPath "$SPHERE_SPM_CLONE_DIR")
  echo "→ Клоны пакетов: $SPHERE_SPM_CLONE_DIR"
fi

set +e
for attempt in 1 2 3; do
  echo "→ Resolve, попытка $attempt из 3…"
  "${XCB[@]}"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "→ Готово. Открой Sphere.xcodeproj → Product → Clean Build Folder → Build."
    exit 0
  fi
  echo "   (код $rc — часто checkout Chat не успел; повтор через 2 с)"
  sleep 2
done
set -e

echo "→ Не вышло за 3 попытки. Освободи ≥3–5 ГБ на диске, проверь сеть/VPN, снова запусти этот скрипт." >&2
exit 1
