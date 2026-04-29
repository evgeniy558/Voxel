#!/usr/bin/env bash
# Восстановление SwiftPM после «Missing package product» / красных пакетов.
#
# Важно: правки .swift не трогают список пакетов в project.pbxproj — ошибка почти всегда из‑за
# битого checkout в DerivedData, нехватки места на диске или гонки при clone пакета Chat.
#
# SPHERE_SPM_FORCE_CLEAN=1 — сразу удалить ~/Library/.../DerivedData/Sphere-*
# SPHERE_SPM_CLONE_DIR=/path — клоны пакетов в отдельную папку
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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

try_resolve() {
  "${XCB[@]}"
}

clean_sphere_derived_data() {
  echo "→ Удаляю ~/Library/Developer/Xcode/DerivedData/Sphere-* …"
  rm -rf "${HOME}/Library/Developer/Xcode/DerivedData/Sphere-"*
}

if [[ "${SPHERE_SPM_FORCE_CLEAN:-}" == 1 ]]; then
  echo "→ SPHERE_SPM_FORCE_CLEAN=1"
  clean_sphere_derived_data
fi

set +e
try_resolve
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "→ Первый resolve не удался — полная очистка DerivedData для Sphere и повтор (закрой Xcode ⌘Q)."
  clean_sphere_derived_data
  for attempt in 1 2 3; do
    echo "→ Resolve после очистки, попытка $attempt из 3…"
    try_resolve
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "→ Готово. Открой проект → Product → Clean Build Folder → Build."
      exit 0
    fi
    echo "   (код $rc — повтор через 2 с; часто не успел записаться Chat/Package.swift)"
    sleep 2
  done
else
  echo "→ resolve OK (DerivedData не трогали — так быстрее и стабильнее)."
  exit 0
fi
set -e

echo "→ Не вышло. Освободи ≥3–5 ГБ на диске; при мало места: SPHERE_SPM_CLONE_DIR=/tmp/SphereSPM" >&2
exit 1
