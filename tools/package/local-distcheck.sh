#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

ZIG_BIN="${ZIG_BIN:-/opt/zig-x86_64-linux-0.15.2/zig}"
BUILD_ARGS=(
  -j1
  -Dapp-runtime=gtk
  -fno-sys=gtk4-layer-shell
)
RELEASE_ARGS=(
  "${BUILD_ARGS[@]}"
  -Doptimize=ReleaseFast
)

if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
  echo "zig binary not found: $ZIG_BIN" >&2
  exit 1
fi

echo "==> Release build"
"$ZIG_BIN" build "${RELEASE_ARGS[@]}"

echo "==> Package metadata validation"
desktop-file-validate zig-out/share/applications/com.termplex.app.desktop
desktop-file-validate zig-out/share/applications/com.termplex.app-debug.desktop
appstreamcli validate --no-net zig-out/share/metainfo/com.termplex.app.metainfo.xml
appstreamcli validate --no-net zig-out/share/metainfo/com.termplex.app-debug.metainfo.xml

echo "==> Source dist tarball"
"$ZIG_BIN" build dist "${BUILD_ARGS[@]}"

archive="$(find zig-out/dist -maxdepth 1 -type f -name 'termplex-*.tar.gz' | sort | tail -n1)"
if [[ -z "$archive" ]]; then
  echo "dist archive not found under zig-out/dist" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo "==> Extracting $archive"
tar -xzf "$archive" -C "$tmpdir"
srcdir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d -name 'termplex-*' | sort | head -n1)"
if [[ -z "$srcdir" ]]; then
  echo "failed to locate extracted source directory" >&2
  exit 1
fi

echo "==> Full test suite in extracted tarball"
(
  cd "$srcdir"
  "$ZIG_BIN" build test "${BUILD_ARGS[@]}"
)

echo "==> Optional package tooling"
for tool in flatpak-builder snapcraft appimage-builder appimagetool; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "found $tool"
  else
    echo "missing $tool (skipped)"
  fi
done

echo "local-distcheck: OK"
