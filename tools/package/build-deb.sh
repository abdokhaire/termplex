#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

ZIG_BIN="${ZIG_BIN:-/opt/zig-x86_64-linux-0.15.2/zig}"
PACKAGE_NAME="${PACKAGE_NAME:-termplex}"
MAINTAINER="${MAINTAINER:-Mitchell Hashimoto <m@mitchellh.com>}"
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

for tool in dpkg-deb dpkg-shlibdeps dpkg fakeroot install; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "required tool not found: $tool" >&2
    exit 1
  fi
done

echo "==> Release build"
"$ZIG_BIN" build "${RELEASE_ARGS[@]}"

echo "==> Dist version"
"$ZIG_BIN" build dist "${BUILD_ARGS[@]}"

archive="$(find zig-out/dist -maxdepth 1 -type f -name 'termplex-*.tar.gz' | sort | tail -n1)"
if [[ -z "$archive" ]]; then
  echo "dist archive not found under zig-out/dist" >&2
  exit 1
fi

raw_version="$(basename "$archive")"
raw_version="${raw_version#termplex-}"
raw_version="${raw_version%.tar.gz}"
sanitized_version="$(printf '%s' "$raw_version" | tr '-' '~')"
deb_version="${DEB_VERSION:-$sanitized_version}"
arch="${DEB_ARCH:-$(dpkg --print-architecture)}"
output_dir="${OUTPUT_DIR:-$ROOT_DIR/zig-out/deb}"
package_stem="${PACKAGE_NAME}_${deb_version}_${arch}"
stage_root="$(mktemp -d)"
stage_dir="$stage_root/$package_stem"

cleanup() {
  rm -rf "$stage_root"
}
trap cleanup EXIT

mkdir -p \
  "$stage_dir/DEBIAN" \
  "$stage_dir/usr/bin" \
  "$stage_dir/usr/lib/termplex" \
  "$output_dir"

echo "==> Staging package tree"
install -Dm755 zig-out/bin/termplex "$stage_dir/usr/bin/termplex"
install -Dm755 zig-out/bin/termplex-ctl "$stage_dir/usr/bin/termplex-ctl"
install -Dm755 zig-out/bin/termplex-app "$stage_dir/usr/lib/termplex/termplex-app.bin"
install -Dm755 zig-out/lib/libgtk4-layer-shell.so "$stage_dir/usr/lib/termplex/libgtk4-layer-shell.so"

while IFS= read -r -d '' path; do
  rel="${path#zig-out/share/}"
  dest="$stage_dir/usr/share/$rel"
  install -Dm644 "$path" "$dest"
done < <(
  find zig-out/share/applications \
       zig-out/share/bash-completion \
       zig-out/share/dbus-1 \
       zig-out/share/fish \
       zig-out/share/icons \
       zig-out/share/kio \
       zig-out/share/locale \
       zig-out/share/metainfo \
       zig-out/share/nautilus-python \
       zig-out/share/nvim \
       zig-out/share/terminfo \
       zig-out/share/termplex \
       zig-out/share/vim \
       zig-out/share/zsh \
       -type f -print0
)

if [[ -d zig-out/share/systemd/user ]]; then
  while IFS= read -r -d '' path; do
    rel="${path#zig-out/share/systemd/user/}"
    install -Dm644 "$path" "$stage_dir/usr/lib/systemd/user/$rel"
  done < <(find zig-out/share/systemd/user -type f -print0)
fi

rm -f \
  "$stage_dir/usr/share/applications/com.termplex.app-debug.desktop" \
  "$stage_dir/usr/share/dbus-1/services/com.termplex.app-debug.service" \
  "$stage_dir/usr/share/metainfo/com.termplex.app-debug.metainfo.xml" \
  "$stage_dir/usr/lib/systemd/user/app-com.termplex.app-debug.service"

cat >"$stage_dir/usr/bin/termplex-app" <<'EOF'
#!/bin/sh
set -eu

export TERMPLEX_RESOURCES_DIR="${TERMPLEX_RESOURCES_DIR:-/usr/share/termplex}"
export LD_LIBRARY_PATH="/usr/lib/termplex${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /usr/lib/termplex/termplex-app.bin "$@"
EOF
chmod 755 "$stage_dir/usr/bin/termplex-app"

sed -i \
  -e 's#^TryExec=.*#TryExec=/usr/bin/termplex-app#' \
  -e 's#^Exec=.* --gtk-single-instance=true#Exec=/usr/bin/termplex-app --gtk-single-instance=true#' \
  "$stage_dir/usr/share/applications/com.termplex.app.desktop"
sed -i \
  -e 's#^Exec=.*#Exec=/usr/bin/termplex-app --gtk-single-instance=true --initial-window=false#' \
  "$stage_dir/usr/share/dbus-1/services/com.termplex.app.service"
sed -i \
  -e 's#^ExecStart=.*#ExecStart=/usr/bin/termplex-app --gtk-single-instance=true --initial-window=false#' \
  "$stage_dir/usr/lib/systemd/user/app-com.termplex.app.service"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$stage_dir/usr/share/applications/com.termplex.app.desktop"
fi
if command -v appstreamcli >/dev/null 2>&1; then
  appstreamcli validate --no-net "$stage_dir/usr/share/metainfo/com.termplex.app.metainfo.xml"
fi

echo "==> Resolving package dependencies"
mkdir -p "$stage_root/debian"
cat >"$stage_root/debian/control" <<EOF
Source: $PACKAGE_NAME
Section: x11
Priority: optional
Maintainer: $MAINTAINER
Standards-Version: 4.7.0

Package: $PACKAGE_NAME
Architecture: $arch
Description: temporary control file for dpkg-shlibdeps
EOF

shlibs_output="$(
  cd "$stage_root" &&
    dpkg-shlibdeps \
      -O \
      --ignore-missing-info \
      -l"$stage_dir/usr/lib/termplex" \
      "$stage_dir/usr/lib/termplex/termplex-app.bin" \
      "$stage_dir/usr/bin/termplex"
)"
depends="${shlibs_output#shlibs:Depends=}"
if [[ -n "$depends" ]]; then
  depends="$depends, python3:any"
else
  depends="python3:any"
fi
installed_size="$(du -sk "$stage_dir/usr" | awk '{print $1}')"

cat >"$stage_dir/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $deb_version
Section: x11
Priority: optional
Architecture: $arch
Maintainer: $MAINTAINER
Installed-Size: $installed_size
Depends: $depends
Homepage: https://termplex.org
Description: Workspace-centric terminal emulator
 Termplex is a workspace-centric terminal emulator for Linux built on the
 Ghostty terminal core. This package includes the GTK app, workspace CLI,
 shell integration assets, themes, and desktop integration files.
EOF

cat >"$stage_dir/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 755 "$stage_dir/DEBIAN/postinst"

cat >"$stage_dir/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 755 "$stage_dir/DEBIAN/postrm"

package_path="$output_dir/$package_stem.deb"

echo "==> Building $package_path"
fakeroot dpkg-deb --build --root-owner-group "$stage_dir" "$package_path"
dpkg-deb -I "$package_path"

echo "deb-package: $package_path"
