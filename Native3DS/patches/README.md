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
| `0005-fixed-open-shared-font.patch` | `externals/open_source_archives/CMakeLists.txt` | Puts `Native3DS/open_source_archives/include` (open-source system font with 20 missing glyphs restored; see `Native3DS/licenses/OpenSharedFont-NOTICE.txt`) ahead of Azahar's own include path when `EDUO_FRONTEND_DIR` is set. |
| `0006-drop-nus-download.patch` | `src/core/CMakeLists.txt`, `src/core/hle/service/am/am.cpp` | Removes `core/nus_download.cpp` (HTTP client for Nintendo's title CDN) from the build, and its unused include. The app cannot download anything from Nintendo. |
| `0007-eduo-save-folder-override.patch` | `src/common/file_util.cpp`, `src/common/file_util.h`, `src/core/file_sys/archive_source_sd_savedata.cpp`, `src/core/file_sys/archive_source_sd_savedata.h`, `src/core/file_sys/savedata_archive.h` | Lets the app point a title's SaveData archive at a folder of its own (`Saves/<game>.3dssave`) instead of the stock `sdmc/Nintendo 3DS/<id0>/<id1>/title/<high>/<low>/data/` layout. Save states keep recording the stock path and map it back to the folder when loaded, so states made before or after the override still load. |
| `0008-eduo-renderer-park.patch` | `src/video_core/renderer_base.h`, `src/video_core/renderer_vulkan/renderer_vulkan.cpp`, `src/video_core/renderer_vulkan/renderer_vulkan.h` | Adds `RendererBase::Park()` (no-op by default; the Vulkan renderer drains its scheduler, both present windows and the device, without tearing anything down). The eDuo core thread calls it right before it parks, because iOS kills an app that submits Metal work from the background. |

The pinned commit is recorded both as the submodule gitlink and as `PIN`
in `scripts/build_3ds_core.sh`; the script refuses to build any other
commit.
