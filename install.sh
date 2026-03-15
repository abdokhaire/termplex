#!/bin/bash
# Termplex installer
# Usage: curl -fsSL https://raw.githubusercontent.com/abdokhaire/termplex/main/install.sh | bash

set -euo pipefail

VERSION="0.1.0"
REPO="abdokhaire/termplex"
INSTALL_DIR="${INSTALL_DIR:-/usr/local}"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "==> Installing Termplex v${VERSION}"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="x86_64" ;;
    *) echo "Error: Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Check dependencies
missing=""
for cmd in gtk4 libadwaita; do
    pkg-config --exists "$cmd" 2>/dev/null || missing="$missing $cmd"
done
if [ -n "$missing" ]; then
    echo "Warning: Missing dependencies:$missing"
    echo "Install them first:"
    echo "  Ubuntu/Debian: sudo apt install libgtk-4-dev libadwaita-1-dev"
    echo "  Fedora:        sudo dnf install gtk4-devel libadwaita-devel"
    echo "  Arch:          sudo pacman -S gtk4 libadwaita"
    echo ""
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
fi

# Download
TARBALL="termplex-${VERSION}-linux-${ARCH_SUFFIX}.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${TARBALL}"
echo "==> Downloading ${URL}"
curl -fSL "$URL" -o "${TMP_DIR}/${TARBALL}"

# Extract
echo "==> Extracting"
tar xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"

# Install
echo "==> Installing to ${INSTALL_DIR} (may require sudo)"
EXTRACTED_DIR="${TMP_DIR}/termplex-${VERSION}-linux-${ARCH_SUFFIX}"

if [ -w "$INSTALL_DIR" ]; then
    cp "$EXTRACTED_DIR/bin/termplex-app" "${INSTALL_DIR}/bin/"
    cp -r "$EXTRACTED_DIR/share/"* "${INSTALL_DIR}/share/" 2>/dev/null || true
else
    sudo cp "$EXTRACTED_DIR/bin/termplex-app" "${INSTALL_DIR}/bin/"
    sudo cp -r "$EXTRACTED_DIR/share/"* "${INSTALL_DIR}/share/" 2>/dev/null || true
fi

# Desktop integration
if [ -d "${HOME}/.local/share/applications" ]; then
    cp "$EXTRACTED_DIR/share/applications/"*.desktop "${HOME}/.local/share/applications/" 2>/dev/null || true
fi

echo ""
echo "==> Termplex v${VERSION} installed successfully!"
echo "    Run: termplex-app"
echo ""
echo "    To uninstall:"
echo "    sudo rm ${INSTALL_DIR}/bin/termplex-app"
