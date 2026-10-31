#!/bin/bash
# Builds the 3DS core (Vendor/azahar, pinned commit) + the eDuo bridge (Native3DS)
# for device and simulator, and merges them into Build/E3DS.xcframework (+ official MoltenVK).
# Versions and audit: Native3DS/patches/README.md. Nothing unpinned there is downloaded.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
AZ=Vendor/azahar
PIN=987f18405073960622e1043bb44005989135c6e1
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode27.1RC.app/Contents/Developer}

[ "$(git -C $AZ rev-parse HEAD)" = "$PIN" ] || { echo "Vendor/azahar no esta en $PIN"; exit 1; }
git -C $AZ submodule update --init --recursive --depth 1 >/dev/null
# Own patches, idempotent.
for p in Native3DS/patches/*.patch; do
  git -C $AZ apply --check "$ROOT/$p" 2>/dev/null && git -C $AZ apply "$ROOT/$p"
done

build() { # $1 = sysroot (iphoneos|iphonesimulator)
  local B=Build/azahar-$1
  cmake -S $AZ -B $B -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$1 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
    -DEDUO_FRONTEND_DIR="$ROOT/Native3DS" \
    -DENABLE_QT=OFF -DENABLE_SDL2=OFF -DENABLE_WEB_SERVICE=OFF -DENABLE_SCRIPTING=OFF \
    -DENABLE_GDBSTUB=OFF -DENABLE_OPENAL=ON -DENABLE_BUILTIN_KEYBLOB=OFF -DENABLE_TESTS=OFF \
    -DENABLE_ROOM=OFF -DENABLE_FFMPEG=OFF -DENABLE_LIBUSB=OFF -DENABLE_CUBEB=OFF \
    -DENABLE_VULKAN=ON -DCITRA_WARNINGS_AS_ERRORS=OFF -DENABLE_LTO=OFF \
    -DCITRA_USE_PRECOMPILED_HEADERS=OFF >/dev/null
  nice ninja -C $B -j${JOBS:-6} eduo3ds
  # A single .a with the bridge and everything it pulls in (except MoltenVK, which ships as a framework).
  local libs; libs=$(/usr/bin/find $B -name '*.a' -not -path '*MoltenVK*' | sort)
  mkdir -p $B/out && rm -f $B/out/libE3DS.a
  libtool -static -no_warning_for_no_symbols -o $B/out/libE3DS.a $libs
}
build iphoneos
build iphonesimulator

rm -rf Build/E3DS.xcframework
xcodebuild -create-xcframework \
  -library Build/azahar-iphoneos/out/libE3DS.a -headers Native3DS/src/E3DS.h \
  -library Build/azahar-iphonesimulator/out/libE3DS.a -headers Native3DS/src/E3DS.h \
  -output Build/E3DS.xcframework >/dev/null
rm -rf Build/MoltenVK.xcframework
cp -R Build/azahar-iphoneos/externals/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework Build/
echo "ok: Build/E3DS.xcframework + Build/MoltenVK.xcframework"
