// E3DS.mm — eDuo's frontend for the Azahar 3DS core.
// Written for eDuo after Azahar's Android frontend (src/android/.../jni/native.cpp,
// emu_window_vk.cpp, 987f184). GPLv2-or-later.
//
// Kept off on purpose (App Store, and nothing should phone out):
//   - CPU and shader JIT: FastInterp + the shader interpreter instead;
//   - web services, rooms, scripting and the GDB stub are compiled out (CMake);
//   - no console keys ship with the app (ENABLE_BUILTIN_KEYBLOB=OFF).

#include "E3DS.h"
#include "input_manager.h"
#include "E3DSHomebrewTag.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <codecvt>
#include <cstdlib>
#include <cstring>
#include <locale>
#include <memory>
#include <mutex>
#include <thread>
#include <chrono>
#include <unordered_map>

#include <fmt/format.h>

#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/settings.h"
#include "core/cheats/cheats.h"
#include "core/cheats/gateway_cheat.h"
#include "core/core.h"
#include "core/hle/kernel/kernel.h"
#include "core/savestate.h"
#include "core/file_sys/archive_source_sd_savedata.h"
#include "core/file_sys/file_backend.h"
#include "core/hle/service/fs/archive.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/image_interface.h"
#include "core/frontend/emu_window.h"
#include "core/loader/loader.h"
#include "core/loader/smdh.h"
#include "core/frontend/input.h"
#include "core/hle/service/service.h"
#include "input_common/motion_emu.h"
#include "video_core/custom_textures/custom_tex_manager.h"
#include "video_core/gpu.h"
#include "video_core/renderer_base.h"
#include "video_core/rasterizer_interface.h"

#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <os/log.h>

#include <mach/mach.h>
#include <mach/thread_info.h>
#include <pthread.h>
#include <chrono>

namespace {

// E3DS.h mirrors these by hand: a drift here once made a game-requested exit (16) read as
// ErrorUnknown, i.e. a "couldn't start this game" alert after a clean exit.
#define E3DS_CHECK_RESULT(name) \
    static_assert((unsigned)E3DSResult##name == (unsigned)Core::System::ResultStatus::name, #name)
E3DS_CHECK_RESULT(Success);
E3DS_CHECK_RESULT(ShutdownRequested);
E3DS_CHECK_RESULT(ErrorUnknown);
static_assert((unsigned)E3DSResultErrorGetLoader == (unsigned)Core::System::ResultStatus::ErrorGetLoader);
static_assert((unsigned)E3DSResultErrorLoader == (unsigned)Core::System::ResultStatus::ErrorLoader);
static_assert((unsigned)E3DSResultErrorEncrypted == (unsigned)Core::System::ResultStatus::ErrorLoader_ErrorEncrypted);
static_assert((unsigned)E3DSResultErrorInvalidFormat == (unsigned)Core::System::ResultStatus::ErrorLoader_ErrorInvalidFormat);
static_assert((unsigned)E3DSResultErrorSystemFiles == (unsigned)Core::System::ResultStatus::ErrorSystemFiles);

class GraphicsContext_iOS final : public Frontend::GraphicsContext {
public:
    std::shared_ptr<Common::DynamicLibrary> GetDriverLibrary() override { return nullptr; }
};

/// One CAMetalLayer, one 3DS screen (layout_option = SeparateWindows: the
/// primary window draws the top screen, the secondary the bottom one).
class EmuWindow_iOS final : public Frontend::EmuWindow {
public:
    EmuWindow_iOS(CAMetalLayer* layer, double width, double height, bool secondary)
        : Frontend::EmuWindow(secondary), layer_(layer) {
        window_info.type = Frontend::WindowSystemType::MacOS; // VK_EXT_metal_surface
        window_info.render_surface = (__bridge void*)layer_;
        window_info.render_surface_scale = layer_ ? (float)layer_.contentsScale : 1.0f;
        Resize(width, height);
    }

    void Resize(double width, double height) {
        UpdateCurrentFramebufferLayout(std::max(1u, (unsigned)width),
                                       std::max(1u, (unsigned)height), false);
    }

    void PollEvents() override {}
    std::unique_ptr<Frontend::GraphicsContext> CreateSharedContext() const override {
        return std::make_unique<GraphicsContext_iOS>();
    }

private:
    CAMetalLayer* layer_;
};

struct Session {
    std::mutex mutex;
    // Guards the input factories: Shutdown (core thread) frees them while the UI thread may
    // still be pressing a button (START on a game that is exiting).
    std::mutex inputMutex;
    std::condition_variable cv;
    std::atomic_bool stop{false}, paused{false}, running{false};
    // True while the core thread sits in the paused wait (no GPU work in flight).
    std::atomic_bool parked{false};
    // Save-state op in progress: the loop keeps iterating even when paused.
    std::atomic_bool stepping{false};
    bool stepFinished = false;
    int stepIters = 0;
    std::chrono::steady_clock::time_point stepDeadline;
    std::condition_variable doneCv;
    std::mutex opMutex;
    bool batterySaver = false;
    int hwShader = -1;  // -1 auto, 0 software vertex shaders, 1 hardware
    CAMetalLayer* top = nil;
    CAMetalLayer* bottom = nil;
    u64 program_id = 0;
    // The player's chosen internal resolution (Settings > 3DS). Never touched by the
    // battery saver: the saver only overrides what is written to Settings::values.
    int resolution = 2;
    double topW = 400, topH = 240, bottomW = 320, bottomH = 240;
    std::unique_ptr<EmuWindow_iOS> window, secondary;
    // Diagnostics (see E3DSSetDiagnostics / E3DSSampleStats).
    int vsync = -1;
    bool unlimited = false;
    // "Dump Textures" for the next E3DSRun (see E3DSSetDumpTextures).
    bool dumpTextures = false;
    std::atomic_bool statsOn{false};
    std::atomic<mach_port_t> coreThread{MACH_PORT_NULL};
    std::atomic<unsigned long long> presents{0};
    __weak CAMetalLayer* countedLayer = nil;
} g;

// Counts nextDrawable calls on the top layer (MoltenVK calls it once per
// presented frame). Installed the first time stats are switched on; a Bool
// test per call afterwards.
IMP g_origNextDrawable = nullptr;
id<CAMetalDrawable> CountingNextDrawable(CAMetalLayer* self, SEL _cmd) {
    if (g.statsOn && self == g.countedLayer) g.presents.fetch_add(1, std::memory_order_relaxed);
    return ((id<CAMetalDrawable>(*)(id, SEL))g_origNextDrawable)(self, _cmd);
}

double ThreadCPUSeconds(thread_act_t t, char* nameOut = nullptr, size_t nameLen = 0) {
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) return 0;
    if (info.flags & TH_FLAGS_IDLE) return 0;
    if (nameOut) {
        nameOut[0] = 0;
        if (pthread_t pt = pthread_from_mach_thread_np(t)) pthread_getname_np(pt, nameOut, nameLen);
    }
    return info.user_time.seconds + info.user_time.microseconds / 1e6 +
           info.system_time.seconds + info.system_time.microseconds / 1e6;
}

void ConfigureOnce() {
    static std::once_flag once;
    std::call_once(once, [] {
        Common::Log::Initialize();
        Common::Log::SetColorConsoleBackendEnabled(false);
        Common::Log::Start();
        // The default profile names motion_emu, and an unregistered engine
        // throws. InputCommon::Init() would also pull in SDL, which is off.
        Input::RegisterFactory<Input::MotionDevice>("motion_emu",
                                                    std::make_shared<InputCommon::MotionEmu>());
    });

    auto& v = Settings::values;
    v.use_cpu_jit.SetValue(false);    // no JIT on the App Store
    v.use_shader_jit.SetValue(false);
    v.use_fastinterp.SetValue(true);
    v.graphics_api.SetValue(Settings::GraphicsAPI::Vulkan);
    v.layout_option.SetValue(Settings::LayoutOption::SeparateWindows);
    v.use_hw_shader.SetValue(true);
    v.resolution_factor.SetValue(static_cast<u32>(g.batterySaver ? 1 : g.resolution));
    v.async_shader_compilation.SetValue(true);
    v.async_presentation.SetValue(true);
    if (g.vsync >= 0) v.use_vsync.SetValue(g.vsync != 0);
    v.frame_limit.SetValue(g.unlimited ? 0.0 : 100.0);
    if (g.batterySaver) {
        v.use_vsync.SetValue(false);
        Settings::is_temporary_frame_limit = true;
        Settings::temporary_frame_limit = 100.0;
    }
    v.output_type.SetValue(AudioCore::SinkType::Auto);

    static const int buttons[Settings::NativeButton::NumButtons] = {
        InputManager::N3DS_BUTTON_A,     InputManager::N3DS_BUTTON_B,
        InputManager::N3DS_BUTTON_X,     InputManager::N3DS_BUTTON_Y,
        InputManager::N3DS_DPAD_UP,      InputManager::N3DS_DPAD_DOWN,
        InputManager::N3DS_DPAD_LEFT,    InputManager::N3DS_DPAD_RIGHT,
        InputManager::N3DS_TRIGGER_L,    InputManager::N3DS_TRIGGER_R,
        InputManager::N3DS_BUTTON_START, InputManager::N3DS_BUTTON_SELECT,
        InputManager::N3DS_BUTTON_DEBUG, InputManager::N3DS_BUTTON_GPIO14,
        InputManager::N3DS_BUTTON_ZL,    InputManager::N3DS_BUTTON_ZR,
        InputManager::N3DS_BUTTON_HOME,
    };
    for (int i = 0; i < Settings::NativeButton::NumButtons; ++i)
        v.current_input_profile.buttons[i] = InputManager::GenerateButtonParamPackage(buttons[i]);
    v.current_input_profile.analogs[Settings::NativeAnalog::CirclePad] =
        InputManager::GenerateAnalogParamPackage(InputManager::N3DS_CIRCLEPAD);
    v.current_input_profile.analogs[Settings::NativeAnalog::CStick] =
        InputManager::GenerateAnalogParamPackage(InputManager::N3DS_STICK_C);
    v.current_input_profile.touch_device = "engine:emu_window";
    // Every system module runs high-level (no console dumps needed); the
    // core looks each one up with .at(), so all of them must be listed.
    for (const auto& module : Service::service_module_map)
        v.lle_modules.emplace(module.name, false);
}

} // namespace

extern "C" {

void E3DSSetLayers(void* topLayer, double topWidth, double topHeight, void* bottomLayer,
                   double bottomWidth, double bottomHeight) {
    std::lock_guard lock(g.mutex);
    g.top = (__bridge CAMetalLayer*)topLayer;
    g.countedLayer = g.top;
    g.bottom = (__bridge CAMetalLayer*)bottomLayer;
    g.topW = topWidth; g.topH = topHeight;
    g.bottomW = bottomWidth; g.bottomH = bottomHeight;
    if (g.window) g.window->Resize(topWidth, topHeight);
    if (g.secondary) g.secondary->Resize(bottomWidth, bottomHeight);
}

// ---- Per-game folders for what the core keys by program ID ------------------------------
// A .3dsx has no program ID (the 3DSX loader doesn't implement ReadProgramId, so the core
// uses 0), and the core names save states (<id>.<slot>.cst) and the cheat file (<id>.txt)
// after it: every homebrew would share one set, and loading another homebrew's state would
// run foreign memory in the wrong program. Homebrew keeps its own data under sdmc:/ and
// never uses the program-ID save folder, so only these two folders need splitting. They are
// pointed at a per-file folder derived from the file's content (path independent, so the same
// homebrew keeps its states if the file is re-imported or moved). Real titles keep the
// stock folders, so nothing existing moves.
static void UsePerGameFolders(u64 program_id, const char* path) {
    const std::string tag = program_id == 0 ? E3DSHomebrewTag(path) : std::string();
    for (auto dir : {FileUtil::UserPath::StatesDir, FileUtil::UserPath::CheatsDir}) {
        const std::string stock = FileUtil::GetDefaultUserPath(dir);
        std::string target = tag.empty() ? stock : stock + tag + "/";
        // Always set it: the previous game's folder must not leak into this one.
        if (!FileUtil::CreateFullPath(target)) target = stock;
        FileUtil::CreateFullPath(stock);
        FileUtil::UpdateUserPath(dir, target);
    }
}

// Save states are written in place by the core ("wb" truncates the slot first), so a failed
// or interrupted write would cost the slot's previous state. The previous file is kept as
// <slot>.prev until the new one is verified; a leftover .prev at the next boot means the
// write never finished, so it goes back (see RestoreInterruptedStates).
static std::string StatePath(int slot) {
    return fmt::format("{}{:016X}.{:02d}.cst", FileUtil::GetUserPath(FileUtil::UserPath::StatesDir),
                       g.program_id, slot);
}

// Texture packs (replacement) and texture dumping, one folder per game keyed by program ID
// (the PPSSPP model):
//   load/textures/<ID>/   the player's pack AND where "Dump Textures" writes (patch 0009)
// Dumping adds the textures the folder does not hold yet (a file already there, edited or not, is
// never dumped again), so dumps accumulate across sessions; the core loads what the player
// edited or added in the same folder at the next boot, no copying. Dumps nobody has edited are
// stamped by the core (IsUntouchedDump) and not loaded as replacements: thousands of identical
// PNGs would only cost RAM and decode time.
// Builds up to 1.2.0 (68) dumped into dump/textures/<ID>/ instead: MigrateLegacyTextureDump
// moves that over.
static bool IsTextureFile(const std::string& name) {
    const auto dot = name.rfind('.');
    if (dot == std::string::npos) return false;
    std::string ext = name.substr(dot + 1);
    for (auto& c : ext) c = (char)tolower((unsigned char)c);
    return ext == "png" || ext == "dds" || ext == "ktx";
}

static std::string TexturePackFolder(u64 program_id) {
    return fmt::format("{}textures/{:016X}/", FileUtil::GetUserPath(FileUtil::UserPath::LoadDir),
                       program_id);
}

struct PackScan {
    int textures = 0;  // png/dds/ktx files, anywhere inside
    int loadable = 0;  // ... of those, the ones the core will load (not untouched dumps)
    bool hasConfig = false;
};

static PackScan ScanPack(const std::string& packs) {
    PackScan scan;
    scan.hasConfig = FileUtil::Exists(packs + "pack.json");
    FileUtil::FSTEntry tree;
    std::vector<FileUtil::FSTEntry> files;
    FileUtil::ScanDirectoryTree(packs, tree, 64);
    FileUtil::GetAllFilesFromNestedEntries(tree, files);
    for (const auto& f : files) {
        if (!IsTextureFile(f.virtualName)) continue;
        ++scan.textures;
        if (!VideoCore::IsUntouchedDump(f.physicalName)) ++scan.loadable;
    }
    return scan;
}

// What the core's old PrepareDumping wrote into the dump folder; now written here, into the
// pack folder, and only when the folder holds no pack yet (see PrepareTexturePacks).
static void WriteTemplatePackConfig(const std::string& packs) {
    FileUtil::IOFile f{packs + "pack.json", "w"};
    f.WriteString(
        "{\n"
        "    \"author\": \"eDuo\",\n"
        "    \"version\": \"1.0.0\",\n"
        "    \"description\": \"Textures dumped by eDuo\",\n"
        "    \"options\": {\n"
        "        \"skip_mipmap\": false,\n"
        "        \"flip_png_files\": true,\n"
        "        \"use_new_hash\": true\n"
        "    }\n"
        "}\n");
}

// Moves what a 1.2.0 (68) dump left in dump/textures/<ID>/ into the pack folder. Never
// overwrites: a file the pack folder already has wins and the other stays where it was. A legacy
// pack (textures but no pack.json) is left alone entirely, because the dump uses the new hash and
// would never match it; pack.json only moves into a pack folder that has neither. Returns the
// number of files moved.
static int MigrateLegacyTextureDump(u64 program_id) {
    const std::string dumped = fmt::format(
        "{}textures/{:016X}/", FileUtil::GetUserPath(FileUtil::UserPath::DumpDir), program_id);
    if (!FileUtil::IsDirectory(dumped)) return 0;
    const std::string packs = TexturePackFolder(program_id);
    const PackScan before = ScanPack(packs);
    if (before.textures > 0 && !before.hasConfig) return 0;  // legacy pack
    FileUtil::CreateFullPath(packs);
    FileUtil::FSTEntry tree;
    FileUtil::ScanDirectoryTree(dumped, tree, 0);
    int moved = 0;
    for (const auto& f : tree.children) {
        if (f.isDirectory) continue;
        const bool isConfig = f.virtualName == "pack.json";
        if (isConfig ? (before.hasConfig || before.textures > 0) : false) continue;
        const std::string dest = packs + f.virtualName;
        if (FileUtil::Exists(dest)) continue;
        if (FileUtil::Rename(f.physicalName, dest)) ++moved;
    }
    FileUtil::DeleteDir(dumped);  // rmdir: only if nothing is left
    return moved;
}

// Fills the three texture settings the core reads while it loads (the rasterizer cache and
// CustomTexManager copy them once, so they only take effect on the next E3DSRun). The pack
// folder is made up front so players find it.
// Dumping needs the new hash, and the core only uses it when the pack folder has a pack.json
// that says so (no pack.json = legacy pack = old hash). So while dumping into a folder that
// holds no pack at all, the template pack.json goes in first. A pack.json that is already there
// is never rewritten, and a legacy pack (textures, no pack.json) stays legacy, dumped with the
// old hash to match its own.
static void PrepareTexturePacks(u64 program_id, bool dump) {
    MigrateLegacyTextureDump(program_id);
    const auto packs = TexturePackFolder(program_id);
    FileUtil::CreateFullPath(packs);
    const PackScan scan = ScanPack(packs);
    if (dump && !scan.hasConfig && scan.textures == 0) WriteTemplatePackConfig(packs);
    // Replacement only when something would actually be loaded; with it on, every texture
    // the game uploads is looked up (and logged when missing).
    Settings::values.custom_textures.SetValue(scan.loadable > 0);
    Settings::values.async_custom_loading.SetValue(true);
    Settings::values.dump_textures.SetValue(dump);
}

static void RestoreInterruptedStates() {
    for (int slot = 0; slot <= (int)Core::SaveStateSlotCount; ++slot) {
        const std::string path = StatePath(slot), prev = path + ".prev";
        if (!FileUtil::Exists(prev)) continue;
        FileUtil::Delete(path);
        FileUtil::Rename(prev, path);
    }
}

// Skinned models vanish on MoltenVK in these games with hardware vertex shaders while the
// scenery draws fine; the software vertex shader (same as Azahar's reference) draws them.
// Matched by title too: regional program IDs are not all known.
// ponytail: list by hand; add games as reports come in.
static bool UseHardwareShaders(u64 program_id, const std::string& title) {
    if (g.hwShader >= 0) return g.hwShader != 0;
    const bool software = program_id == 0x0004000000061300 ||  // Tales of the Abyss
                          title.find("Abyss") != std::string::npos ||
                          title.find("アビス") != std::string::npos;
    if (software) LOG_INFO(Frontend, "eDuo: software vertex shaders for {:016X} {}", program_id, title);
    return !software;
}

int E3DSRun(const char* path) {
    if (!path || g.running.exchange(true)) return (int)Core::System::ResultStatus::ErrorUnknown;
    g.stop = false;
    g.paused = false;
    ConfigureOnce();

    Core::System& system = Core::System::GetInstance();
    {
        std::lock_guard lock(g.mutex);
        g.window = std::make_unique<EmuWindow_iOS>(g.top, g.topW, g.topH, false);
        g.secondary = std::make_unique<EmuWindow_iOS>(g.bottom, g.bottomW, g.bottomH, true);
    }

    u64 program_id = 0;
    std::string title;
    FileUtil::SetCurrentRomPath(path);
    auto loader = Loader::GetLoader(path);
    g.program_id = 0;
    if (loader) {
        loader->ReadProgramId(program_id);
        loader->ReadTitle(title, false);
        g.program_id = program_id;
        system.RegisterAppLoaderEarly(loader);
        PrepareTexturePacks(program_id, g.dumpTextures);
    } else {
        Settings::values.dump_textures.SetValue(false);
    }
    UsePerGameFolders(program_id, path);
    Settings::values.use_hw_shader.SetValue(UseHardwareShaders(program_id, title));
    RestoreInterruptedStates();
    system.ApplySettings();
    Frontend::RegisterDefaultApplets(system);
    {
        std::lock_guard lock(g.inputMutex);
        InputManager::Init();
    }

    auto result = system.Load(*g.window, path, g.secondary.get());
    if (result == Core::System::ResultStatus::Success) {
        system.GPU().ApplyPerProgramSettings(program_id);
        std::atomic_bool stop_loading{false};
        system.GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(stop_loading, nullptr);
        system.RegisterCoreLoopThreadId();
        g.coreThread = pthread_mach_thread_np(pthread_self());

        while (!g.stop) {
            if (g.paused && !g.stepping) {
                // Parking means NO GPU work, not just no new frames: the scheduler worker and
                // the present thread are still holding the last ones. iOS kills an app that
                // submits Metal work from the background, so drain them first (also on the
                // pause menu, where it costs one frame). The stdio flush gets whatever the
                // game wrote to its save out of the buffers before iOS may suspend or kill us.
                system.GPU().Renderer().Park();
                fflush(nullptr);
                std::unique_lock lock(g.mutex);
                g.parked = true;
                g.cv.wait(lock, [] { return !g.paused || g.stop || g.stepping; });
                g.parked = false;
                continue;
            }
            // The save/load request runs at the start of a RunLoop in which no
            // async kernel operation is pending; that iteration ends the step.
            const bool stepThis = g.stepping;
            const bool asyncBefore = stepThis && system.Kernel().AreAsyncOperationsPending();
            result = system.RunLoop();
            if (g.stepping) {
                ++g.stepIters;
                if ((stepThis && !asyncBefore) ||
                    std::chrono::steady_clock::now() > g.stepDeadline) {
                    std::lock_guard lock(g.mutex);
                    g.stepping = false;
                    g.stepFinished = true;
                    g.doneCv.notify_all();
                }
            }
            // A failed save/load must not kill the game.
            if (result == Core::System::ResultStatus::ErrorSavestate ||
                result == Core::System::ResultStatus::ErrorSavestateBuildMismatch) {
                result = Core::System::ResultStatus::Success;
                continue;
            }
            if (result != Core::System::ResultStatus::Success) break;
        }
        if (g.stop) result = Core::System::ResultStatus::Success;
    }

    g.coreThread = MACH_PORT_NULL;
    system.Shutdown();
    // The game's save files are plain stdio streams; a game that wrote without the flush flag
    // and never closed the file leaves its data in the stream buffer. Shutdown normally closes
    // every file, but a leaked handle would hold that data back from the next boot and from a
    // kill. Flushes every open output stream of the process; harmless when nothing is pending.
    fflush(nullptr);
    {
        std::lock_guard lock(g.inputMutex);
        InputManager::Shutdown();
    }
    {
        std::lock_guard lock(g.mutex);
        g.window.reset();
        g.secondary.reset();
    }
    g.running = false;
    {
        std::lock_guard lock(g.mutex);
        g.stepping = false;
        g.stepFinished = true;
        g.doneCv.notify_all();
    }
    return (int)result;
}

void E3DSSetResolution(int factor) {
    g.resolution = std::clamp(factor, 1, 10);  // Azahar allows up to 18; the menu tops out at 9x (~4K)
    // Mid-game change (the player picked a new value while the saver is off): the rasterizer
    // cache polls resolution_factor every frame, so this also applies live.
    if (g.running && !g.batterySaver)
        Settings::values.resolution_factor.SetValue(static_cast<u32>(g.resolution));
}

void E3DSSetDumpTextures(bool on) {
    g.dumpTextures = on;
}

int E3DSMigrateTextureDump(unsigned long long programID) {
    ConfigureOnce();
    return MigrateLegacyTextureDump(programID);
}

void E3DSStop(void) {
    g.stop = true;
    g.cv.notify_all();
}

void E3DSSetPaused(bool paused) {
    g.paused = paused;
    g.cv.notify_all();
}

bool E3DSWaitParked(int timeoutMs) {
    for (int i = 0; i < timeoutMs && g.running && !g.parked; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    return g.parked || !g.running;
}

// Battery saver. Transient: the player's resolution stays in g.resolution (and the app's
// stored prefs); only the live Settings::values entries are overridden and then restored
// from it, so turning the saver off gives back exactly the chosen value.
//  * resolution_factor -> 1 (native). The rasterizer cache polls it each frame and rebuilds
//    its surfaces (one hitch), so it applies live, no renderer recreate and no restart.
//  * use_vsync -> off, i.e. Azahar's immediate present mode. The presenter hands frames to
//    the compositor without blocking the core, so the app can ask iOS for a 30 Hz display
//    (see ThreeDSGameViewController) without halving the speed of 60 fps games. The core is
//    still paced by the 100 % frame limiter, never by the display.
//  * Not touched: cpu_clock_percentage, emulation speed, texture filter / post-processing
//    (eDuo never changes them from Azahar's cheap defaults), async shader compilation (on).
void E3DSSetBatterySaver(bool on) {
    const bool was = g.batterySaver;
    g.batterySaver = on;
    auto& v = Settings::values;
    const u32 oldFactor = v.resolution_factor.GetValue();
    if (on) {
        v.resolution_factor.SetValue(1);
        v.use_vsync.SetValue(false);
        Settings::is_temporary_frame_limit = true;
        Settings::temporary_frame_limit = 100.0;
    } else {
        v.resolution_factor.SetValue(static_cast<u32>(g.resolution));
        Settings::is_temporary_frame_limit = false;
        // Core default (true on iOS) unless diagnostics force a value.
        v.use_vsync.SetValue(g.vsync >= 0 ? g.vsync != 0 : true);
    }
    os_log(OS_LOG_DEFAULT, "[eDuo3DS] battery saver %{public}s -> %{public}s: resolution_factor %u -> %u, vsync %d, running %d",
           was ? "on" : "off", on ? "on" : "off", oldFactor, v.resolution_factor.GetValue(),
           (int)v.use_vsync.GetValue(), (int)g.running.load());
}

// Runs a save/load request on the core thread, even while paused. Blocks
// up to ~7 s; must not be called from the core thread.
static int RunStateOp(Core::System::Signal signal, int slot) {
    if (!g.running || g.coreThread == pthread_mach_thread_np(pthread_self())) return -1;
    std::lock_guard op(g.opMutex);
    std::unique_lock lock(g.mutex);
    if (!Core::System::GetInstance().SendSignal(signal, (u32)slot)) return -2;
    g.stepFinished = false;
    g.stepIters = 0;
    g.stepDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(6);
    g.stepping = true;
    g.cv.notify_all();
    g.doneCv.wait_for(lock, std::chrono::seconds(8), [] { return g.stepFinished; });
    return g.stepFinished ? 0 : -3;
}

int E3DSSaveState(int slot) {
    if (slot < 0 || slot > (int)Core::SaveStateSlotCount) return -1;
    const auto before = Core::GetSaveStateInfo(g.program_id, 0, (u32)slot);
    const auto start = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    const std::string path = StatePath(slot), prev = path + ".prev";
    const bool hadOld = before.slot != 0xFFFFFFFFu && FileUtil::Exists(path);
    if (hadOld) {
        FileUtil::Delete(prev);
        if (!FileUtil::Copy(path, prev)) return -4; // can't protect the old one: don't risk it
    }
    int r = RunStateOp(Core::System::Signal::Save, slot);
    // Verify the file was written (the core gives up silently after 5 s of async ops).
    int result = r;
    if (r == 0) {
        const auto after = Core::GetSaveStateInfo(g.program_id, 0, (u32)slot);
        result = (after.slot != 0xFFFFFFFFu && (long long)after.time >= (long long)start - 1) ? 0 : -4;
    }
    if (hadOld) {
        if (result == 0) {
            FileUtil::Delete(prev);
        } else if (r != -3) { // -3 = the core may still write: leave .prev for the next boot
            FileUtil::Delete(path);
            FileUtil::Rename(prev, path);
        }
    }
    return result;
}

int E3DSLoadState(int slot) {
    if (slot < 0 || slot > (int)Core::SaveStateSlotCount) return -1;
    const auto info = Core::GetSaveStateInfo(g.program_id, 0, (u32)slot);
    if (info.slot == 0xFFFFFFFFu) return -5; // no such state
    if (info.status != Core::SaveStateInfo::ValidationStatus::OK) return -6; // other build
    return RunStateOp(Core::System::Signal::Load, slot);
}

bool E3DSStateInfo(int slot, long long* unixTime) {
    if (slot < 0 || slot > (int)Core::SaveStateSlotCount) return false;
    const auto info = Core::GetSaveStateInfo(g.program_id, 0, (u32)slot);
    if (info.slot == 0xFFFFFFFFu) return false;
    if (unixTime) *unixTime = (long long)info.time;
    return true;
}

bool E3DSIsRunning(void) { return g.running; }

void E3DSSetButton(int button, bool pressed) {
    std::lock_guard lock(g.inputMutex);
    if (auto* handler = InputManager::ButtonHandler())
        pressed ? handler->PressKey(button) : handler->ReleaseKey(button);
}

void E3DSSetStick(int stick, float x, float y) {
    std::lock_guard lock(g.inputMutex);
    if (auto* handler = InputManager::AnalogHandler()) handler->MoveJoystick(stick, x, y);
}

void E3DSTouch(bool down, float x, float y) {
    std::lock_guard lock(g.mutex);
    if (!g.secondary) return;
    if (down) {
        const unsigned px = (unsigned)std::max(0.f, x), py = (unsigned)std::max(0.f, y);
        if (!g.secondary->TouchPressed(px, py)) g.secondary->TouchMoved(px, py);
    } else {
        g.secondary->TouchReleased();
    }
}

char* E3DSCopyTitle(const char* path) {
    auto loader = Loader::GetLoader(path);
    if (!loader) return nullptr;
    std::vector<u8> smdh_data;
    loader->ReadIcon(smdh_data, true);
    if (!Loader::IsValidSMDH(smdh_data)) return nullptr;
    Loader::SMDH smdh;
    std::memcpy(&smdh, smdh_data.data(), sizeof(Loader::SMDH));
    const auto& raw = smdh.titles[static_cast<int>(Loader::SMDH::TitleLanguage::English)].long_title;
    std::u16string title(reinterpret_cast<const char16_t*>(raw.data()));
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> convert;
    return strdup(convert.to_bytes(title).c_str());
}

unsigned char* E3DSCopyIcon(const char* path, int* width, int* height) {
    if (width) *width = 0;
    if (height) *height = 0;
    if (!path) return nullptr;
    auto loader = Loader::GetLoader(path);
    if (!loader) return nullptr;
    std::vector<u8> smdh_data;
    loader->ReadIcon(smdh_data, true);
    if (!Loader::IsValidSMDH(smdh_data)) return nullptr;
    Loader::SMDH smdh;
    std::memcpy(&smdh, smdh_data.data(), sizeof(Loader::SMDH));
    constexpr int kSide = 48;
    const std::vector<u16> rgb565 = smdh.GetIcon(true);  // untiled, row-major
    if (rgb565.size() != static_cast<std::size_t>(kSide * kSide)) return nullptr;
    auto* rgba = static_cast<unsigned char*>(std::malloc(rgb565.size() * 4));
    if (!rgba) return nullptr;
    // Expand each 5/6/5 channel to 8 bits by replicating the top bits (0x1F -> 0xFF).
    for (std::size_t i = 0; i < rgb565.size(); ++i) {
        const u16 p = rgb565[i];
        const unsigned r = (p >> 11) & 0x1F, gr = (p >> 5) & 0x3F, b = p & 0x1F;
        rgba[i * 4 + 0] = static_cast<unsigned char>((r << 3) | (r >> 2));
        rgba[i * 4 + 1] = static_cast<unsigned char>((gr << 2) | (gr >> 4));
        rgba[i * 4 + 2] = static_cast<unsigned char>((b << 3) | (b >> 2));
        rgba[i * 4 + 3] = 0xFF;
    }
    if (width) *width = kSide;
    if (height) *height = kSide;
    return rgba;
}

unsigned long long E3DSProgramID(const char* path) {
    u64 id = 0;
    if (auto loader = Loader::GetLoader(path)) loader->ReadProgramId(id);
    return id;
}

// ---- Per-game save folder --------------------------------------------------------------
// The core reads the folder on every save access (Open/Format/GetFormatInfo), so this can be
// set before E3DSRun and stays until changed. A .3dsx (program ID 0) never gets one.
void E3DSSetSaveDataFolder(unsigned long long programID, const char* folder) {
    if (programID == 0) return;
    FileSys::ArchiveSource_SDSaveData::SetSaveDataFolderOverride(programID,
                                                                 folder ? folder : "");
}

char* E3DSCopyLegacySaveFolder(unsigned long long programID) {
    return strdup(FileSys::ArchiveSource_SDSaveData::GetStockSaveDataPathFor(
                      FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir), programID)
                      .c_str());
}

int E3DSSaveSelfTest(const char* folder, char* report, int reportLength) {
    std::string out;
    int failures = 0;
    auto check = [&](bool ok, const char* what, const std::string& detail = std::string()) {
        out += ok ? "PASS " : "FAIL ";
        out += what;
        if (!detail.empty()) { out += ' '; out += detail; }
        out += '\n';
        if (!ok) ++failures;
    };
    constexpr u64 kPid = 0x00040000000ED500ULL;  // fake title: never a real game
    constexpr std::size_t kSize = 4096;
    std::string base = folder ? folder : "";
    bool overrideSet = false;
    try {
        ConfigureOnce();  // initializes logging; nothing else here needs a running System
        if (base.empty()) {
            check(false, "folder", "empty folder");
            if (report && reportLength > 0) snprintf(report, (size_t)reportLength, "%s", out.c_str());
            return failures;
        }
        if (base.back() != '/') base += '/';
        const std::string sdmc = FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir);
        const std::string stock = FileSys::ArchiveSource_SDSaveData::GetStockSaveDataPathFor(sdmc, kPid);
        const std::string dataFile = base + "00000001/eduo-selftest.bin";
        const std::string metaFile = base + "00000001.metadata";

        // Fresh run: nothing from a previous one, in the folder or in the stock place.
        FileUtil::DeleteDirRecursively(base);
        static const std::string kStockTail = "data/00000001/";
        if (stock.size() > kStockTail.size() &&
            stock.compare(stock.size() - kStockTail.size(), kStockTail.size(), kStockTail) == 0)
            FileUtil::DeleteDirRecursively(stock.substr(0, stock.size() - kStockTail.size()));

        std::vector<u8> pattern(kSize);
        for (std::size_t i = 0; i < kSize; ++i) pattern[i] = (u8)((i * 31 + 7) ^ (i >> 8));

        FileSys::ArchiveSource_SDSaveData::SetSaveDataFolderOverride(kPid, base);
        overrideSet = true;

        const FileSys::Path archivePath(FileSys::LowPathType::Empty, {});
        const FileSys::Path filePath("/eduo-selftest.bin");
        {
            FileSys::ArchiveSource_SDSaveData src(sdmc);
            FileSys::ArchiveFormatInfo info{};
            info.total_size = 0x80000;
            info.number_directories = 16;
            info.number_files = 16;
            info.duplicate_data = 0;
            const Result fmtRes = src.Format(kPid, info, Service::FS::ArchiveIdCode::SaveData,
                                             archivePath, 0, 0);
            check(R_SUCCEEDED(fmtRes), "format", fmt::format("raw={:08x}", fmtRes.raw));

            auto opened = src.Open(Service::FS::ArchiveIdCode::SaveData, archivePath, kPid);
            check(opened.Succeeded(), "open", fmt::format("raw={:08x}", opened.Code().raw));
            if (opened.Succeeded()) {
                // What a game does: create, open, write without the flush flag, close.
                std::unique_ptr<FileSys::ArchiveBackend> archive = std::move(opened.Unwrap());
                const Result created = archive->CreateFile(filePath, kSize, 0);
                FileSys::Mode mode;
                mode.hex = 0;
                mode.read_flag.Assign(1);
                mode.write_flag.Assign(1);
                mode.create_flag.Assign(1);
                {
                    auto file = archive->OpenFile(filePath, mode, 0);
                    if (R_SUCCEEDED(created) && file.Succeeded()) {
                        auto wrote = file.Unwrap()->Write(0, kSize, false, false, pattern.data());
                        if (!wrote.Succeeded() || wrote.Unwrap() != kSize)
                            check(false, "write", "short or failed write");
                        file.Unwrap()->Close();
                    } else {
                        check(false, "create/open file",
                              fmt::format("create={:08x} open={:08x}", created.raw,
                                          file.Code().raw));
                    }
                }  // file backend destroyed here, then the archive
                archive.reset();
            }

            // (3) the bytes are in the folder.
            {
                std::vector<u8> back(kSize + 1, 0);
                std::size_t n = 0;
                const bool exists = FileUtil::Exists(dataFile);
                if (FILE* f = fopen(dataFile.c_str(), "rb")) {
                    n = fread(back.data(), 1, back.size(), f);
                    fclose(f);
                }
                const bool same = exists && n == kSize && memcmp(back.data(), pattern.data(), kSize) == 0;
                check(same, "file-in-folder", fmt::format("{} exists={} bytes={}", dataFile, exists, n));
            }
            // (4) metadata is in the folder and readable through the core.
            {
                const bool exists = FileUtil::Exists(metaFile);
                auto fi = src.GetFormatInfo(kPid, Service::FS::ArchiveIdCode::SaveData, archivePath);
                const u32 total = fi.Succeeded() ? (u32)fi.Unwrap().total_size : 0;
                check(exists && fi.Succeeded() && total == 0x80000, "metadata",
                      fmt::format("{} exists={} total_size={:#x}", metaFile, exists, total));
            }
        }  // src destroyed: next boot starts from a fresh source

        // (5) nothing went to the stock place.
        check(!FileUtil::Exists(stock), "no-legacy-write", stock);

        // (6) save states record the stock path, and it maps back to the folder.
        {
            const std::string saved = FileUtil::SerializePath(dataFile, true);
            // Placeholder, not an absolute path (stock SerializePath swaps %CITRA_USER_DIR% first,
            // and sdmc/ lives under it, so that is the one a state records).
            const bool prefix = saved.rfind("%CITRA_USER_DIR%sdmc/Nintendo 3DS/", 0) == 0 ||
                                saved.rfind("%CITRA_USER_SDMC%Nintendo 3DS/", 0) == 0;
            const bool tail = saved.find("title/00040000/000ed500/data/00000001/eduo-selftest.bin") !=
                              std::string::npos;
            const std::string loaded = FileUtil::SerializePath(saved, false);
            check(prefix && tail && loaded == dataFile, "state-path-map",
                  fmt::format("saved={} loaded={}", saved, loaded));
        }

        // (7) a fresh source (next boot) finds and reads the file.
        {
            FileSys::ArchiveSource_SDSaveData src2(sdmc);
            auto opened = src2.Open(Service::FS::ArchiveIdCode::SaveData, archivePath, kPid);
            bool same = false;
            if (opened.Succeeded()) {
                std::unique_ptr<FileSys::ArchiveBackend> archive = std::move(opened.Unwrap());
                auto file = archive->OpenFile(filePath, FileSys::Mode::ReadOnly(), 0);
                if (file.Succeeded()) {
                    std::vector<u8> back(kSize, 0);
                    auto rd = file.Unwrap()->Read(0, kSize, back.data());
                    same = rd.Succeeded() && rd.Unwrap() == kSize &&
                           memcmp(back.data(), pattern.data(), kSize) == 0;
                    file.Unwrap()->Close();
                }
            }
            check(same, "reopen-after-restart");
        }
    } catch (...) {
        check(false, "exception", "self-test aborted");
    }
    if (overrideSet) {
        try {
            FileSys::ArchiveSource_SDSaveData::SetSaveDataFolderOverride(kPid, "");
        } catch (...) {
        }
    }
    if (report && reportLength > 0) {
        const std::size_t n = std::min<std::size_t>(out.size(), (std::size_t)reportLength - 1);
        memcpy(report, out.data(), n);
        report[n] = 0;
    }
    return failures;
}

int E3DSTextureDumpSelfTest(char* report, int reportLength) {
    std::string out;
    int failures = 0;
    auto check = [&](bool ok, const char* what, const std::string& detail = std::string()) {
        out += ok ? "PASS " : "FAIL ";
        out += what;
        if (!detail.empty()) { out += ' '; out += detail; }
        out += '\n';
        if (!ok) ++failures;
    };
    constexpr u64 kPid = 0x00040000000ED700ULL;  // fake title: never a real game
    try {
        ConfigureOnce();
        const std::string load = FileUtil::GetUserPath(FileUtil::UserPath::LoadDir);
        const std::string dump = FileUtil::GetUserPath(FileUtil::UserPath::DumpDir);
        // Both must sit in Documents/System, the folder Files shows.
        check(load.find("/Documents/System/load/") != std::string::npos, "load-dir-in-documents", load);
        check(dump.find("/Documents/System/dump/") != std::string::npos, "dump-dir-in-documents", dump);

        // One folder per game: the pack folder is also where the dumps go (patch 0009).
        const std::string packs = fmt::format("{}textures/{:016X}/", load, kPid);
        const std::string legacy = fmt::format("{}textures/{:016X}/", dump, kPid);
        check(packs == TexturePackFolder(kPid), "single-folder-path", packs);
        const std::string json = packs + "pack.json";
        const std::string pngA = "tex1_8x8_00000000000000A1_1_mip0.png";
        const std::string pngB = "tex1_8x8_00000000000000B2_1_mip0.png";
        auto& v = Settings::values;
        auto reset = [&] {
            FileUtil::DeleteDirRecursively(packs);
            FileUtil::DeleteDirRecursively(legacy);
        };
        auto put = [&](const std::string& path, const std::string& text) {
            FileUtil::CreateFullPath(path);
            FileUtil::IOFile f{path, "wb"};
            f.WriteString(text);
        };
        auto read = [&](const std::string& path) {
            std::string text(FileUtil::GetSize(path), '\0');
            if (FileUtil::IOFile f{path, "rb"}; f.IsOpen()) f.ReadBytes(text.data(), text.size());
            return text;
        };
        auto isNewHash = [&](const std::string& text) {
            return text.find("\"use_new_hash\": true") != std::string::npos;
        };
        reset();

        // Dump on, empty folder: the folder gets the template pack.json (new hash, so the core
        // never falls back to the legacy hash); nothing to load yet, so replacement stays off.
        PrepareTexturePacks(kPid, true);
        check(v.dump_textures.GetValue() && !v.custom_textures.GetValue(), "dump-on-flags");
        check(FileUtil::IsDirectory(packs) && isNewHash(read(json)), "dump-on-writes-new-hash-config");
        check(!FileUtil::Exists(legacy), "dump-on-leaves-old-dump-folder-unused");
        // Dump off, empty folder: made, no config, nothing dumped.
        reset();
        PrepareTexturePacks(kPid, false);
        check(!v.dump_textures.GetValue() && !v.custom_textures.GetValue(), "dump-off-flags");
        check(FileUtil::IsDirectory(packs) && !FileUtil::Exists(json), "dump-off-makes-folder-only");

        // Accumulating: dumps (stamped untouched) are kept and not loaded; an edited one is
        // loaded. The edit changes the file's modification time, even at the same size.
        reset();
        PrepareTexturePacks(kPid, true);
        const std::string dumpedText = "0123456789";
        put(packs + pngA, dumpedText);
        put(packs + pngB, dumpedText);
        check(VideoCore::MarkUntouchedDump(packs + pngA) && VideoCore::MarkUntouchedDump(packs + pngB),
              "mark-dumps");
        check(VideoCore::IsUntouchedDump(packs + pngA), "marked-dump-is-untouched");
        PrepareTexturePacks(kPid, true);
        check(FileUtil::Exists(packs + pngA) && FileUtil::Exists(packs + pngB) &&
                  read(packs + pngA) == dumpedText && !v.custom_textures.GetValue(),
              "untouched-dumps-kept-not-loaded");
        put(packs + pngB, "9876543210");  // same size, new content, new mtime
        check(!VideoCore::IsUntouchedDump(packs + pngB), "edited-same-size-not-untouched");
        PrepareTexturePacks(kPid, true);
        check(v.custom_textures.GetValue() && v.dump_textures.GetValue() &&
                  FileUtil::Exists(packs + pngA) && read(packs + pngB) == "9876543210",
              "edited-texture-loads-with-dump-on");
        PrepareTexturePacks(kPid, false);
        check(v.custom_textures.GetValue() && !v.dump_textures.GetValue(), "edited-texture-loads-with-dump-off");

        // A pack.json the player edited is never rewritten (even one asking for the old hash).
        reset();
        const std::string mine = "{\"options\":{\"skip_mipmap\":true,\"flip_png_files\":true,\"use_new_hash\":false}}";
        put(json, mine);
        PrepareTexturePacks(kPid, true);
        check(read(json) == mine, "user-pack-json-not-overwritten");
        // A legacy pack (textures, no pack.json) stays legacy: no config appears.
        reset();
        put(packs + pngA, "legacy");
        PrepareTexturePacks(kPid, true);
        check(!FileUtil::Exists(json) && v.custom_textures.GetValue(), "legacy-pack-gets-no-config");

        // Migration from build 68: dump/textures/<ID> moves into the pack folder.
        reset();
        put(legacy + pngA, "dumpA");
        put(legacy + pngB, "dumpB");
        put(legacy + "pack.json", "{\"options\": {\"use_new_hash\": true}}");
        check(MigrateLegacyTextureDump(kPid) == 3, "migrate-moves-everything");
        check(read(packs + pngA) == "dumpA" && read(packs + pngB) == "dumpB" &&
                  isNewHash(read(json)) && !FileUtil::Exists(legacy),
              "migrate-result-and-old-folder-gone");
        check(MigrateLegacyTextureDump(kPid) == 0, "migrate-idempotent");
        // ... never over the player's files, nor the player's pack.json.
        reset();
        put(json, mine);
        put(packs + pngB, "mine");
        put(legacy + pngA, "dumpA");
        put(legacy + pngB, "dumpB");
        put(legacy + "pack.json", "{\"options\": {\"use_new_hash\": true}}");
        check(MigrateLegacyTextureDump(kPid) == 1, "migrate-skips-existing");
        check(read(packs + pngA) == "dumpA" && read(packs + pngB) == "mine" && read(json) == mine &&
                  read(legacy + pngB) == "dumpB" && FileUtil::Exists(legacy + "pack.json"),
              "migrate-never-overwrites");
        // ... and never into a legacy pack (different hash): left where it was.
        reset();
        put(packs + pngA, "legacy");
        put(legacy + pngB, "dumpB");
        put(legacy + "pack.json", "{\"options\": {\"use_new_hash\": true}}");
        check(MigrateLegacyTextureDump(kPid) == 0 && !FileUtil::Exists(json) &&
                  FileUtil::Exists(legacy + pngB),
              "migrate-leaves-legacy-pack-alone");
        // Booting does the migration too.
        reset();
        put(legacy + pngA, "dumpA");
        PrepareTexturePacks(kPid, false);
        check(FileUtil::Exists(packs + pngA) && !FileUtil::Exists(legacy), "boot-migrates");

        // The encoder the core's DumpTexture uses (default Frontend::ImageInterface), into the
        // pack folder, and back.
        reset();
        FileUtil::CreateFullPath(packs);
        const std::string png = packs + "tex1_2x2_selftest.png";
        const std::vector<u8> rgba = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 9, 9, 255};
        Frontend::ImageInterface images;
        check(images.EncodePNG(png, 2, 2, rgba) && FileUtil::Exists(png), "encode-png-into-pack-folder");
        std::vector<u8> bytes(FileUtil::GetSize(png));
        if (FileUtil::IOFile f{png, "rb"}; f.IsOpen()) f.ReadBytes(bytes.data(), bytes.size());
        std::vector<u8> back;
        u32 w = 0, h = 0;
        check(images.DecodePNG(back, w, h, bytes) && w == 2 && h == 2 && back == rgba, "decode-png-roundtrip");
        // What DumpTexture does right after encoding: stamp it; the scan then ignores it.
        check(VideoCore::MarkUntouchedDump(png) && VideoCore::IsUntouchedDump(png) &&
                  ScanPack(packs).loadable == 0 && ScanPack(packs).textures == 1,
              "stamped-dump-is-skipped-by-scan");

        reset();
        v.dump_textures.SetValue(false);
        v.custom_textures.SetValue(false);
    } catch (...) {
        check(false, "exception", "self-test aborted");
    }
    if (report && reportLength > 0) {
        const std::size_t n = std::min<std::size_t>(out.size(), (std::size_t)reportLength - 1);
        memcpy(report, out.data(), n);
        report[n] = 0;
    }
    return failures;
}

char* E3DSCopyCheatFile(unsigned long long programID) {
    return strdup(fmt::format("{}{:016X}.txt",
                              FileUtil::GetUserPath(FileUtil::UserPath::CheatsDir), programID)
                      .c_str());
}

void E3DSReloadCheats(void) {
    if (!g.running) return;
    // The engine only reads the file once per title (LoadCheatFile caches
    // the ID), so swap the list in place.
    auto& engine = Core::System::GetInstance().CheatEngine();
    while (!engine.GetCheats().empty()) engine.RemoveCheat(0);
    char* path = E3DSCopyCheatFile(g.program_id);
    for (auto& cheat : Cheats::GatewayCheat::LoadFile(path)) engine.AddCheat(std::move(cheat));
    free(path);
}

} // extern "C"

extern "C" {

void E3DSSetDiagnostics(int vsync, bool unlimitedSpeed) {
    g.vsync = vsync;
    g.unlimited = unlimitedSpeed;
}

void E3DSSetHardwareShaders(int mode) { g.hwShader = mode; }

void E3DSSetStatsEnabled(bool enabled) {
    if (enabled) {
        static std::once_flag hook;
        std::call_once(hook, [] {
            Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
            if (m) g_origNextDrawable = method_setImplementation(m, (IMP)CountingNextDrawable);
        });
    }
    g.statsOn = enabled;
}

bool E3DSSampleStats(E3DSStats* out) {
    using clock = std::chrono::steady_clock;
    static clock::time_point lastWall;
    static double lastCore = 0, lastProc = 0;
    static unsigned long long lastPresents = 0;
    static std::unordered_map<mach_port_t, double> lastThread;
    if (!out || !g.statsOn || !g.running) return false;
    const mach_port_t core = g.coreThread;
    if (core == MACH_PORT_NULL) return false;

    const auto now = clock::now();
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return false;
    double coreCPU = 0, proc = 0, hot = 0;
    char hotName[32] = {0};
    std::unordered_map<mach_port_t, double> current;
    const double dt = std::chrono::duration<double>(now - lastWall).count();
    for (mach_msg_type_number_t i = 0; i < n; ++i) {
        char name[32];
        const double cpu = ThreadCPUSeconds(threads[i], name, sizeof name);
        proc += cpu;
        current[threads[i]] = cpu;
        if (threads[i] == core) { coreCPU = cpu; continue; }
        const auto prev = lastThread.find(threads[i]);
        const double delta = cpu - (prev == lastThread.end() ? 0 : prev->second);
        if (dt > 0 && delta > hot) { hot = delta; std::memcpy(hotName, name, sizeof hotName); }
    }
    for (mach_msg_type_number_t i = 0; i < n; ++i) mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_act_t));

    const bool first = lastWall.time_since_epoch().count() == 0;
    const unsigned long long presents = g.presents;
    const double pr = first || dt <= 0 ? 0 : (presents - lastPresents) / dt;
    out->coreCPU = first || dt <= 0 ? 0 : (coreCPU - lastCore) * 100 / dt;
    out->processCPU = first || dt <= 0 ? 0 : (proc - lastProc) * 100 / dt;
    out->hotCPU = first || dt <= 0 ? 0 : hot * 100 / dt;
    std::memcpy(out->hotThread, hotName, sizeof hotName);
    out->hotThread[sizeof out->hotThread - 1] = 0;
    out->presentFPS = pr;
    lastWall = now; lastCore = coreCPU; lastProc = proc; lastPresents = presents;
    lastThread = std::move(current);

    // Core::System resets its counters on every call, so this window is ours.
    const auto perf = Core::System::GetInstance().GetAndResetPerfStats();
    out->emulationSpeed = perf.emulation_speed * 100.0;
    out->gameFPS = perf.game_fps;
    out->systemFPS = perf.system_fps;
    return !first;
}

} // extern "C"
