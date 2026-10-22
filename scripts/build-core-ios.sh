#!/usr/bin/env bash
# Builds Azahar + the AzaharCore frontend for iOS (arm64 device) and merges everything into
# build/ios-<flavor>/lib/libAzaharCore.a, plus build/MoltenVK/MoltenVK.xcframework.
#
#   ./scripts/build-core-ios.sh                    # sideload flavour (JIT allowed), device
#   ./scripts/build-core-ios.sh --flavor appstore  # App Store flavour (no JIT, no built-in keys)
#   ./scripts/build-core-ios.sh --sdk simulator    # arm64 iOS Simulator (Apple silicon Macs)
#
# Requirements (macOS): Xcode 16+, CMake ≥ 3.25, Ninja  →  brew install cmake ninja
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${AZAHAR_SRC:-$ROOT/external/azahar}"
FLAVOR="sideload"
SDK="device"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

while [ $# -gt 0 ]; do
  case "$1" in
    --flavor) FLAVOR="$2"; shift 2 ;;
    --sdk) SDK="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$FLAVOR" in sideload|appstore) ;; *) echo "flavor must be sideload or appstore" >&2; exit 2 ;; esac
case "$SDK" in
  device) SYSROOT=iphoneos; SUFFIX="" ;;
  simulator) SYSROOT=iphonesimulator; SUFFIX="-sim" ;;
  *) echo "sdk must be device or simulator" >&2; exit 2 ;;
esac

[ -d "$SRC/src/azios" ] || "$ROOT/scripts/bootstrap.sh"

BUILD="$ROOT/build/ios$SUFFIX-$FLAVOR"
if [ "$FLAVOR" = "appstore" ]; then
  KEYBLOB=OFF; APPSTORE=ON
else
  KEYBLOB=ON; APPSTORE=OFF
fi

echo "==> Configuring ($FLAVOR, $SDK)"
cmake -S "$SRC" -B "$BUILD/cmake" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_QT=OFF -DENABLE_SDL2=OFF -DENABLE_TESTS=OFF -DENABLE_ROOM=OFF \
  -DENABLE_OPENGL=OFF -DENABLE_VULKAN=ON \
  -DENABLE_CUBEB=OFF -DENABLE_OPENAL=ON -DENABLE_LIBUSB=OFF \
  -DENABLE_WEB_SERVICE=ON -DENABLE_SCRIPTING=OFF -DENABLE_GDBSTUB=OFF \
  -DENABLE_DISCORD_RPC=OFF -DENABLE_LTO=OFF \
  -DCITRA_WARNINGS_AS_ERRORS=OFF -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
  -DENABLE_BUILTIN_KEYBLOB="$KEYBLOB" \
  -DENABLE_AZIOS=ON -DAZIOS_APPSTORE="$APPSTORE"

echo "==> Building (jobs: $JOBS — the first build takes a while)"
cmake --build "$BUILD/cmake" --target azios -j "$JOBS"

echo "==> Merging static libraries"
mkdir -p "$BUILD/lib"
LIBS=()
while IFS= read -r lib; do LIBS+=("$lib"); done < <(
  find "$BUILD/cmake" -name '*.a' ! -path '*/MoltenVK/*' ! -name 'libMoltenVK.a' | sort)
libtool -static -no_warning_for_no_symbols -o "$BUILD/lib/libAzaharCore.a" "${LIBS[@]}" 2> >(grep -v "same member name" >&2 || true)
echo "    ${#LIBS[@]} libraries → $BUILD/lib/libAzaharCore.a ($(du -h "$BUILD/lib/libAzaharCore.a" | cut -f1))"

echo "==> MoltenVK (dynamic framework, embedded in the app)"
MVK="$BUILD/cmake/externals/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework"
if [ ! -d "$MVK" ]; then
  MVK="$(find "$BUILD/cmake/externals" -type d -path '*dynamic/MoltenVK.xcframework' | head -n1)"
fi
[ -d "$MVK" ] || { echo "error: MoltenVK dynamic xcframework not found under $BUILD/cmake/externals" >&2; exit 1; }
mkdir -p "$ROOT/build/MoltenVK"
rm -rf "$ROOT/build/MoltenVK/MoltenVK.xcframework"
cp -R "$MVK" "$ROOT/build/MoltenVK/"

echo "Done. Next: xcodegen generate && open Bifold.xcodeproj"
