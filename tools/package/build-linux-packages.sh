#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

skip_missing=false
targets=()

for arg in "$@"; do
  case "$arg" in
    --skip-missing) skip_missing=true ;;
    all) targets=(deb appimage flatpak snap) ;;
    deb|appimage|flatpak|snap) targets+=("$arg") ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: $0 [--skip-missing] [all|deb|appimage|flatpak|snap ...]" >&2
      exit 1
      ;;
  esac
done

if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(deb appimage flatpak snap)
fi

success=()
skipped=()
failed=()

run_target() {
  local name="$1"
  shift

  local status=0
  if "$@"; then
    status=0
  else
    status=$?
  fi

  if [[ $status -eq 0 ]]; then
    success+=("$name")
    return 0
  fi

  if [[ $status -eq 3 && "$skip_missing" == true ]]; then
    skipped+=("$name")
    return 0
  fi

  failed+=("$name")
  return "$status"
}

for target in "${targets[@]}"; do
  case "$target" in
    deb)
      run_target deb tools/package/build-deb.sh || true
      ;;
    appimage)
      before_success=${#success[@]}
      run_target appimage env APPIMAGE_SKIP_DEB_BUILD=1 tools/package/build-appimage.sh || true
      if [[ ${#success[@]} -gt $before_success ]]; then
        echo "==> Update manifest"
        echo "Generate with tools/package/write-update-manifest.py after release URLs are known."
      fi
      ;;
    flatpak)
      run_target flatpak tools/package/build-flatpak.sh || true
      ;;
    snap)
      run_target snap tools/package/build-snap.sh || true
      ;;
  esac
done

printf 'package-success: %s\n' "${success[*]:-none}"
printf 'package-skipped: %s\n' "${skipped[*]:-none}"
printf 'package-failed: %s\n' "${failed[*]:-none}"

if [[ ${#failed[@]} -gt 0 ]]; then
  exit 1
fi
