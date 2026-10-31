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

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <codecvt>
#include <cstring>
#include <locale>
#include <memory>
#include <mutex>

#include <fmt/format.h>

#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/settings.h"
#include "core/cheats/cheats.h"
#include "core/cheats/gateway_cheat.h"
#include "core/core.h"
#include "core/file_sys/archive_source_sd_savedata.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/emu_window.h"
#include "core/loader/loader.h"
#include "core/loader/smdh.h"
#include "core/frontend/input.h"
#include "core/hle/service/service.h"
#include "input_common/motion_emu.h"
#include "video_core/gpu.h"
#include "video_core/renderer_base.h"
#include "video_core/rasterizer_interface.h"

#import <QuartzCore/CAMetalLayer.h>

namespace {

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
    std::condition_variable cv;
    std::atomic_bool stop{false}, paused{false}, running{false};
    CAMetalLayer* top = nil;
    CAMetalLayer* bottom = nil;
    u64 program_id = 0;
    int resolution = 2;
    double topW = 400, topH = 240, bottomW = 320, bottomH = 240;
    std::unique_ptr<EmuWindow_iOS> window, secondary;
} g;

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
    v.resolution_factor.SetValue(static_cast<u32>(g.resolution));
    v.async_shader_compilation.SetValue(true);
    v.async_presentation.SetValue(true);
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
    g.bottom = (__bridge CAMetalLayer*)bottomLayer;
    g.topW = topWidth; g.topH = topHeight;
    g.bottomW = bottomWidth; g.bottomH = bottomHeight;
    if (g.window) g.window->Resize(topWidth, topHeight);
    if (g.secondary) g.secondary->Resize(bottomWidth, bottomHeight);
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
    FileUtil::SetCurrentRomPath(path);
    auto loader = Loader::GetLoader(path);
    if (loader) {
        loader->ReadProgramId(program_id);
        g.program_id = program_id;
        system.RegisterAppLoaderEarly(loader);
        // Texture packs: Files → eDuo → System → load → textures → <program ID>.
        // The folder is made up front so players find it; the loader (and its
        // worker threads) only runs when there is a pack inside.
        const auto packs = fmt::format("{}textures/{:016X}/",
                                       FileUtil::GetUserPath(FileUtil::UserPath::LoadDir), program_id);
        FileUtil::CreateFullPath(packs);
        FileUtil::FSTEntry entries;
        Settings::values.custom_textures.SetValue(FileUtil::ScanDirectoryTree(packs, entries) > 0);
        Settings::values.async_custom_loading.SetValue(true);
    }
    system.ApplySettings();
    Frontend::RegisterDefaultApplets(system);
    InputManager::Init();

    auto result = system.Load(*g.window, path, g.secondary.get());
    if (result == Core::System::ResultStatus::Success) {
        system.GPU().ApplyPerProgramSettings(program_id);
        std::atomic_bool stop_loading{false};
        system.GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(stop_loading, nullptr);
        system.RegisterCoreLoopThreadId();

        while (!g.stop) {
            if (g.paused) {
                std::unique_lock lock(g.mutex);
                g.cv.wait(lock, [] { return !g.paused || g.stop; });
                continue;
            }
            result = system.RunLoop();
            if (result != Core::System::ResultStatus::Success) break;
        }
        if (g.stop) result = Core::System::ResultStatus::Success;
    }

    system.Shutdown();
    InputManager::Shutdown();
    {
        std::lock_guard lock(g.mutex);
        g.window.reset();
        g.secondary.reset();
    }
    g.running = false;
    return (int)result;
}

void E3DSSetResolution(int factor) { g.resolution = std::clamp(factor, 1, 4); }

void E3DSStop(void) {
    g.stop = true;
    g.cv.notify_all();
}

void E3DSSetPaused(bool paused) {
    g.paused = paused;
    g.cv.notify_all();
}

bool E3DSIsRunning(void) { return g.running; }

void E3DSSetButton(int button, bool pressed) {
    if (auto* handler = InputManager::ButtonHandler())
        pressed ? handler->PressKey(button) : handler->ReleaseKey(button);
}

void E3DSSetStick(int stick, float x, float y) {
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

unsigned long long E3DSProgramID(const char* path) {
    u64 id = 0;
    if (auto loader = Loader::GetLoader(path)) loader->ReadProgramId(id);
    return id;
}

char* E3DSCopySaveFolder(unsigned long long programID) {
    return strdup(FileSys::ArchiveSource_SDSaveData::GetSaveDataPathFor(
                      FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir), programID)
                      .c_str());
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
