import ProjectDescription

let project = Project(
    name: "eNDS",
    organizationName: "MLS",
    targets: [
        Target(
            name: "eNDS",
            platform: .iOS,
            product: .app,
            bundleId: "com.mls.inds",
            deploymentTarget: .iOS(targetVersion: "17.0", devices: [.iphone, .ipad]),
            infoPlist: .file(path: "Targets/INDS/SupportingFiles/Info.plist"),
            sources: ["Targets/INDS/Sources/**"],
            resources: ["Targets/INDS/Resources/**"],
            dependencies: [
                .sdk(name: "AVFoundation", type: .framework),
                .sdk(name: "ReplayKit", type: .framework),
                // Second handheld format: Azahar core + eDuo frontend
                // (scripts/build_3ds_core.sh) and the official MoltenVK.
                .xcframework(path: "Build/E3DS.xcframework"),
                .xcframework(path: "Build/MoltenVK.xcframework"),
                .sdk(name: "AudioToolbox", type: .framework),
                .sdk(name: "CoreAudio", type: .framework),
                .sdk(name: "Metal", type: .framework),
                .sdk(name: "QuartzCore", type: .framework),
                .sdk(name: "IOSurface", type: .framework),
                .sdk(name: "GameController", type: .framework)
            ],
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "CPJ98JGHA8",
                "SWIFT_VERSION": "5.0",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
                "CLANG_CXX_LIBRARY": "libc++",
                "HEADER_SEARCH_PATHS": [
                    "$(SRCROOT)/Vendor/melonDS/src",
                    "$(SRCROOT)/Vendor/melonDS/src/teakra/include",
                    "$(SRCROOT)/Build/melonDS-ios/src",
                    "$(SRCROOT)/Build/melonDS-ios-sim/src",
                    // Vendored LZMA SDK (.7z import, see Sources/Model/Sz7zShim.c)
                    "$(SRCROOT)/Targets/INDS/Sources/Vendor/lzma",
                    // E3DS.h (3DS core frontend)
                    "$(SRCROOT)/Native3DS/src"
                ],
                "LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": [
                    "$(SRCROOT)/Build/melonDS-ios/src/$(CONFIGURATION)-iphoneos",
                    "$(SRCROOT)/Build/melonDS-ios/src/teakra/src/$(CONFIGURATION)-iphoneos"
                ],
                "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": [
                    "$(SRCROOT)/Build/melonDS-ios-sim/src/$(CONFIGURATION)-iphonesimulator",
                    "$(SRCROOT)/Build/melonDS-ios-sim/src/teakra/src/$(CONFIGURATION)-iphonesimulator"
                ],
                "OTHER_LDFLAGS": [
                    "$(inherited)",
                    "-lcore",
                    "-lteakra",
                    "-lc++",
                    "-lz"
                ],
                "SWIFT_OBJC_BRIDGING_HEADER": "Targets/INDS/Sources/eNDS-Bridging-Header.h"
            ])
        ),
        // App Store screenshot harness (see Targets/INDSScreenshots) — it is
        // launched with -eNDSScreenshotHarness and is not part of the archive.
        Target(
            name: "INDSScreenshots",
            platform: .iOS,
            product: .uiTests,
            bundleId: "com.mls.inds.screenshots",
            deploymentTarget: .iOS(targetVersion: "17.0", devices: [.iphone, .ipad]),
            infoPlist: .default,
            sources: ["Targets/INDSScreenshots/**"],
            dependencies: [.target(name: "eNDS")],
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "CPJ98JGHA8",
                "SWIFT_VERSION": "5.0"
            ])
        )
    ]
)
