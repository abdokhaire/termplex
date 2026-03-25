#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

ZIG_BIN="${ZIG_BIN:-/opt/zig-x86_64-linux-0.15.2/zig}"
MANIFEST="${FLATPAK_MANIFEST:-$ROOT_DIR/flatpak/com.termplex.app.yml}"
BUILD_ARGS=(
  -j1
  -Dapp-runtime=gtk
  -fno-sys=gtk4-layer-shell
)
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/zig-out/packages}"
FLATPAK_BUILDDIR="${FLATPAK_BUILDDIR:-$ROOT_DIR/flatpak/builddir}"
FLATPAK_REPO="${FLATPAK_REPO:-$ROOT_DIR/flatpak/repo}"

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "required tool not found: flatpak-builder" >&2
  exit 3
fi
if ! command -v flatpak >/dev/null 2>&1; then
  echo "required tool not found: flatpak" >&2
  exit 3
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "flatpak manifest not found: $MANIFEST" >&2
  exit 1
fi

if ! flatpak remotes --user --columns=name | grep -Fxq flathub; then
  echo "==> Adding user flathub remote"
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

echo "==> Dist version"
"$ZIG_BIN" build dist "${BUILD_ARGS[@]}"

archive="$(find zig-out/dist -maxdepth 1 -type f -name 'termplex-*.tar.gz' | sort | tail -n1)"
if [[ -z "$archive" ]]; then
  echo "dist archive not found under zig-out/dist" >&2
  exit 1
fi

version="$(basename "$archive")"
version="${version#termplex-}"
version="${version%.tar.gz}"
app_id="$(sed -n 's/^app-id:[[:space:]]*//p' "$MANIFEST" | head -n1)"
branch="$(sed -n 's/^default-branch:[[:space:]]*//p' "$MANIFEST" | head -n1 | tr -d '"')"
branch="${branch:-tip}"

if [[ -z "$app_id" ]]; then
  echo "failed to determine app-id from $MANIFEST" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "==> Flatpak build"
flatpak-builder \
  --user \
  --install-deps-from=flathub \
  --force-clean \
  --repo="$FLATPAK_REPO" \
  "$FLATPAK_BUILDDIR" \
  "$MANIFEST"

bundle_path="$OUTPUT_DIR/${app_id}-${version}.flatpak"
echo "==> Flatpak bundle $bundle_path"
flatpak build-bundle "$FLATPAK_REPO" "$bundle_path" "$app_id" "$branch"

echo "flatpak-package: $bundle_path"
