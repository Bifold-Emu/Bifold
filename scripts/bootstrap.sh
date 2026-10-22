#!/usr/bin/env bash
# Fetches the Azahar emulator source at a pinned tag, applies the iOS patches and links the
# AzaharCore frontend layer into the tree. Safe to run repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AZAHAR_TAG="${AZAHAR_TAG:-2126.2}"
SRC="${AZAHAR_SRC:-$ROOT/external/azahar}"

echo "==> Azahar $AZAHAR_TAG → $SRC"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --branch "$AZAHAR_TAG" --depth 1 https://github.com/azahar-emu/azahar "$SRC"
fi
echo "==> Submodules (this downloads ~1.5 GB the first time)"
git -C "$SRC" submodule update --init --recursive --depth 1 -j 8

apply_patch() {
  local dir="$1" patch="$2"
  if git -C "$dir" apply --check "$patch" 2>/dev/null; then
    git -C "$dir" apply "$patch"
    echo "    applied   $(basename "$patch")"
  elif git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
    echo "    present   $(basename "$patch")"
  else
    echo "error: $(basename "$patch") does not apply to $dir (different Azahar version?)" >&2
    exit 1
  fi
}

echo "==> Patches"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0001-ios-frontend-support.patch"
apply_patch "$SRC/externals/dynarmic"                "$ROOT/patches/dynarmic/0001-ios-dual-mapped-jit.patch"
# Azahar builds its own externals/oaknut (dynarmic then skips its bundled copy); patch both so
# whichever copy CMake picks has the iOS JIT changes.
apply_patch "$SRC/externals/oaknut"                  "$ROOT/patches/oaknut/0001-ios26-jit-arena.patch"
apply_patch "$SRC/externals/dynarmic/externals/oaknut" "$ROOT/patches/oaknut/0001-ios26-jit-arena.patch"

echo "==> Linking Core/ as src/azios"
ln -sfn "$ROOT/Core" "$SRC/src/azios"

echo "Done. Next: ./scripts/build-core-ios.sh"
