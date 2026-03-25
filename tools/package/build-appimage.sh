#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

stage_only=false
for arg in "$@"; do
  case "$arg" in
    --stage-only) stage_only=true ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/zig-out/packages}"
APPDIR="${APPDIR:-$ROOT_DIR/zig-out/appimage/AppDir}"
if [[ "$stage_only" != true ]] && ! command -v appimagetool >/dev/null 2>&1 && ! command -v linuxdeploy >/dev/null 2>&1; then
  echo "required tool not found: appimagetool or linuxdeploy" >&2
  exit 3
fi

deb_path="$(find zig-out/deb -maxdepth 1 -type f -name 'termplex_*.deb' | sort | tail -n1)"
if [[ -z "$deb_path" || "${APPIMAGE_SKIP_DEB_BUILD:-0}" != "1" ]]; then
  echo "==> Debian staging source"
  tools/package/build-deb.sh
  deb_path="$(find zig-out/deb -maxdepth 1 -type f -name 'termplex_*.deb' | sort | tail -n1)"
fi
if [[ -z "$deb_path" ]]; then
  echo "deb artifact not found under zig-out/deb" >&2
  exit 1
fi

deb_base="$(basename "$deb_path")"
deb_version="${deb_base#termplex_}"
deb_version="${deb_version%_*}"
version="${deb_version//\~/-}"
arch="${deb_base##*_}"
arch="${arch%.deb}"
case "$arch" in
  amd64) appimage_arch="x86_64" ;;
  arm64) appimage_arch="aarch64" ;;
  *) appimage_arch="$arch" ;;
esac

echo "==> AppDir staging"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
dpkg-deb -x "$deb_path" "$APPDIR"

cat >"$APPDIR/AppRun" <<'EOF'
#!/bin/sh
set -eu

appdir="${APPDIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
export TERMPLEX_RESOURCES_DIR="${TERMPLEX_RESOURCES_DIR:-$appdir/usr/share/termplex}"
export LD_LIBRARY_PATH="$appdir/usr/lib/termplex${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$appdir/usr/lib/termplex/termplex-app.bin" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

cat >"$APPDIR/usr/bin/termplex-app" <<'EOF'
#!/bin/sh
set -eu

appdir="${APPDIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
export TERMPLEX_RESOURCES_DIR="${TERMPLEX_RESOURCES_DIR:-$appdir/usr/share/termplex}"
export LD_LIBRARY_PATH="$appdir/usr/lib/termplex${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$appdir/usr/lib/termplex/termplex-app.bin" "$@"
EOF
chmod 755 "$APPDIR/usr/bin/termplex-app"

cp "$APPDIR/usr/share/applications/com.termplex.app.desktop" "$APPDIR/termplex.desktop"
sed -i \
  -e 's#^TryExec=.*#TryExec=termplex-app#' \
  -e 's#^Exec=.*#Exec=termplex-app --gtk-single-instance=true#' \
  -e 's#^DBusActivatable=true#DBusActivatable=false#' \
  "$APPDIR/termplex.desktop"

cp "$APPDIR/usr/share/icons/hicolor/512x512/apps/com.termplex.app.png" "$APPDIR/com.termplex.app.png"

if [[ "$stage_only" == true ]]; then
  echo "appimage-appdir: $APPDIR"
  exit 0
fi

mkdir -p "$OUTPUT_DIR"
appimage_path="$OUTPUT_DIR/Termplex-${version}-${appimage_arch}.AppImage"

if command -v linuxdeploy >/dev/null 2>&1; then
  echo "==> linuxdeploy bundling"
  ARCH="$appimage_arch" linuxdeploy \
    --appdir "$APPDIR" \
    --desktop-file "$APPDIR/termplex.desktop" \
    --icon-file "$APPDIR/com.termplex.app.png"
fi

if command -v appimagetool >/dev/null 2>&1; then
  echo "==> AppImage bundle $appimage_path"
  ARCH="$appimage_arch" appimagetool "$APPDIR" "$appimage_path"
  echo "appimage-package: $appimage_path"
  exit 0
fi

if command -v linuxdeploy >/dev/null 2>&1; then
  echo "==> linuxdeploy AppImage output"
  before="$(mktemp)"
  after="$(mktemp)"
  cleanup() {
    rm -f "$before" "$after"
  }
  trap cleanup EXIT
  find "$ROOT_DIR" -maxdepth 1 -type f -name '*.AppImage' | sort >"$before"
  ARCH="$appimage_arch" linuxdeploy \
    --appdir "$APPDIR" \
    --desktop-file "$APPDIR/termplex.desktop" \
    --icon-file "$APPDIR/com.termplex.app.png" \
    --output appimage
  find "$ROOT_DIR" -maxdepth 1 -type f -name '*.AppImage' | sort >"$after"
  produced="$(comm -13 "$before" "$after" | tail -n1)"
  if [[ -z "$produced" ]]; then
    produced="$(find "$ROOT_DIR" -maxdepth 1 -type f -name '*.AppImage' | sort | tail -n1)"
  fi
  if [[ -z "$produced" ]]; then
    echo "linuxdeploy did not produce an AppImage artifact" >&2
    exit 1
  fi
  mv -f "$produced" "$appimage_path"
  echo "appimage-package: $appimage_path"
  exit 0
fi

echo "required tool not found: appimagetool or linuxdeploy" >&2
exit 3
