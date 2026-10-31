# Patches applied to Azahar

`Vendor/azahar` is a git submodule pinned to an exact upstream Azahar
commit and is kept unmodified in git. Everything eDuo changes in it lives
here, as plain `git diff` patches, and `scripts/build_3ds_core.sh` applies
them before building:

```sh
for p in Native3DS/patches/*.patch; do
  git -C Vendor/azahar apply --check "$p" && git -C Vendor/azahar apply "$p"
done
```

Order is the numeric prefix (shell glob order). Each patch is applied only
if `git apply --check` passes, so re-running the script on an already
patched tree is a no-op. To get back to pristine upstream:
`git -C Vendor/azahar checkout -- .`

| Patch | Touches | Why |
|---|---|---|
| `0001-apple-utils-ios.patch` | `src/common/apple_utils.mm` | Builds the Apple helpers on iOS (UIKit instead of AppKit; fixed 60 Hz refresh rate, as iOS has no `NSScreen`). |
| `0002-eduo-frontend-and-moltenvk-framework.patch` | `src/CMakeLists.txt`, `src/video_core/renderer_vulkan/vk_platform.cpp` | Adds the eDuo frontend (`Native3DS/`) as a subdirectory when `EDUO_FRONTEND_DIR` is set; loads MoltenVK from the embedded framework. |
| `0003-ios-data-folder-and-log-name.patch` | `src/common/common_paths.h` | On iOS: data folder `Documents/System` and log file `core_log.txt`. |
| `0004-prefer-dumped-shared-font.patch` | `src/core/hle/service/apt/apt.cpp` | Use the system font the player dumped from their own console, when present, before the bundled open-source replacement. |

The pinned commit is recorded both as the submodule gitlink and as `PIN`
in `scripts/build_3ds_core.sh`; the script refuses to build any other
commit.
