#!/bin/zsh
# Builds Burrow's QEMU: stock QEMU plus scripts/qemu/*.patch (60 Hz display refresh),
# for Apple silicon with Hypervisor.framework, installed where Burrow looks first:
#   ~/Library/Application Support/Burrow/QEMU   (beside $BURROW_HOME when that is set)
# Needs Homebrew's qemu dependencies plus meson and ninja:
#   brew install meson ninja pkgconf glib pixman libslirp
# Usage: ./scripts/build-qemu.sh [path/to/qemu-X.Y.Z.tar.xz]
set -euo pipefail
cd "${0:A:h}/.."

VERSION=11.1.2
SHA256=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
# BURROW_HOME names the Machines folder; Burrow looks for QEMU beside it.
HOME_DIR=${BURROW_HOME:+${BURROW_HOME:h}}
HOME_DIR=${HOME_DIR:-"$HOME/Library/Application Support/Burrow"}
DEST="$HOME_DIR/QEMU"
PATCHES=$PWD/scripts/qemu

WORK=$(mktemp -d /tmp/burrow-qemu-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

TARBALL=${1:-}
if [[ -z $TARBALL ]]; then
  TARBALL=$WORK/qemu-$VERSION.tar.xz
  curl -fsSL -o "$TARBALL" "https://download.qemu.org/qemu-$VERSION.tar.xz"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

tar -xf "$TARBALL" -C "$WORK"
SRC=$WORK/qemu-$VERSION
for patch in "$PATCHES"/*.patch; do
  patch -d "$SRC" -p1 --forward < "$patch"
done

# --disable-pvg: the macOS-guest graphics device uses APIs the macOS 27 SDK removed, and
# Windows guests don't need it.
# A short build path without spaces keeps meson and the entitlement step happy.
mkdir -p "$WORK/build"
cd "$WORK/build"
# QEMU's build needs Python 3.11+ (tomllib); macOS's own python3 is older.
PYTHON=python3
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  [[ -x $candidate ]] && { PYTHON=$candidate; break; }
done
"$SRC/configure" \
  --python="$PYTHON" \
  --prefix="$WORK/install" \
  --target-list=aarch64-softmmu \
  --enable-hvf --enable-slirp --enable-vnc --enable-coreaudio \
  --disable-docs --disable-guest-agent --disable-tools --disable-gtk --disable-sdl \
  --disable-pvg \
  --disable-werror
ninja
ninja install

# QEMU finds its firmware and keymaps relative to the binary, so the tree can move.
rm -rf "$DEST.new"
mkdir -p "$HOME_DIR"
cp -R "$WORK/install" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
"$DEST/bin/qemu-system-aarch64" --version | head -1
echo "Installed Burrow's QEMU to $DEST"
