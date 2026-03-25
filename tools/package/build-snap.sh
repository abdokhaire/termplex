#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/zig-out/packages}"
SNAPCRAFT_BUILD_ENVIRONMENT="${SNAPCRAFT_BUILD_ENVIRONMENT:-host}"
export SNAPCRAFT_BUILD_ENVIRONMENT

if ! command -v snapcraft >/dev/null 2>&1; then
  echo "required tool not found: snapcraft" >&2
  exit 3
fi

SNAPCRAFT_CMD=(snapcraft --destructive-mode)
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  SNAPCRAFT_CMD=(sudo snapcraft --destructive-mode)
fi

mkdir -p "$OUTPUT_DIR"

before="$(mktemp)"
after="$(mktemp)"
cleanup() {
  rm -f "$before" "$after"
}
trap cleanup EXIT

find "$ROOT_DIR" -maxdepth 1 -type f -name 'termplex_*.snap' | sort >"$before"

echo "==> Snap build"
"${SNAPCRAFT_CMD[@]}"

find "$ROOT_DIR" -maxdepth 1 -type f -name 'termplex_*.snap' | sort >"$after"
snap_path="$(comm -13 "$before" "$after" | tail -n1)"
if [[ -z "$snap_path" ]]; then
  snap_path="$(find "$ROOT_DIR" -maxdepth 1 -type f -name 'termplex_*.snap' | sort | tail -n1)"
fi
if [[ -z "$snap_path" ]]; then
  echo "snapcraft did not produce a termplex_*.snap artifact" >&2
  exit 1
fi

final_path="$OUTPUT_DIR/$(basename "$snap_path")"
if [[ "$snap_path" != "$final_path" ]]; then
  mv -f "$snap_path" "$final_path"
else
  final_path="$snap_path"
fi

echo "snap-package: $final_path"
