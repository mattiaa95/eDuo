# Building eDuo

Requirements: Xcode 16 or newer, CMake (`brew install cmake`). The Xcode
project in this repo is already generated; [Tuist 3.12](https://tuist.io) is
only needed if you change `Project.swift` (`tuist generate`). Last verified
end-to-end with Xcode 26 and CMake 4.2. `DEVELOPMENT_TEAM` in `Project.swift`
is the upstream team — replace it with your own to run on a device.

## 1. Get the melonDS core

```sh
git submodule update --init Vendor/melonDS
```

`Vendor/melonDS` is unmodified upstream melonDS, pinned to the exact commit
each eDuo release builds against.

## 2. Build the melonDS static libraries

Device:

```sh
cmake -S Vendor/melonDS -B Build/melonDS-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DENABLE_JIT=OFF -DENABLE_OGLRENDERER=OFF -DENABLE_GDBSTUB=OFF \
  -DENABLE_LTO_RELEASE=ON -DBUILD_QT_SDL=OFF \
  "-DCMAKE_C_FLAGS=-ffile-prefix-map=$PWD=eNDS" \
  "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$PWD=eNDS"
cmake --build Build/melonDS-ios --config Release --target core
```

Simulator:

```sh
cmake -S Vendor/melonDS -B Build/melonDS-ios-sim -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DENABLE_JIT=OFF -DENABLE_OGLRENDERER=OFF -DENABLE_GDBSTUB=OFF \
  -DENABLE_LTO_RELEASE=ON -DBUILD_QT_SDL=OFF \
  "-DCMAKE_C_FLAGS=-ffile-prefix-map=$PWD=eNDS" \
  "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$PWD=eNDS"
cmake --build Build/melonDS-ios-sim --config Debug --target core
```

This produces `libcore.a` / `libteakra.a` under
`Build/melonDS-ios{,-sim}/src/...`, which is where the app's
`LIBRARY_SEARCH_PATHS` (see `Project.swift`) expect them.

## 3. Build the app

```sh
xcodebuild -workspace eNDS.xcworkspace -scheme eNDS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

or just open `eNDS.xcworkspace` in Xcode and run the `eNDS` scheme. To run
on a device, set your own development team in Signing & Capabilities.
