// Internal shared declarations for the AzaharCore iOS frontend.
// Licensed under GPLv2 or any later version.

#pragma once

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "AzaharCore.h"
#include "core/frontend/emu_window.h"

namespace Common {
class DynamicLibrary;
}

namespace AzIOS {

// ----- strings ---------------------------------------------------------------------------------
/// Copies a std::string into a malloc'd C string (released with az_free).
char* DupString(const std::string& s);

// ----- window ----------------------------------------------------------------------------------
/// EmuWindow backed by a CAMetalLayer (Vulkan via MoltenVK). On non-Apple hosts (unit tests)
/// it becomes a headless window so the software renderer can run.
class EmuWindowApple final : public Frontend::EmuWindow {
public:
    explicit EmuWindowApple(std::shared_ptr<Common::DynamicLibrary> driver_library);
    ~EmuWindowApple() override;

    /// Returns true when something changed and the renderer must recreate its swapchain.
    bool SetSurface(void* surface, int width, int height, bool is_portrait);
    void RelayoutForCurrentSettings();

    bool HasSurface() const {
        return window_info.render_surface != nullptr;
    }

    void PollEvents() override {}
    void MakeCurrent() override {}
    void DoneCurrent() override {}
    std::unique_ptr<Frontend::GraphicsContext> CreateSharedContext() const override;
    std::shared_ptr<Common::DynamicLibrary> GetDriverLibrary() override;

    bool OnTouchBegin(float x, float y);
    void OnTouchMove(float x, float y);
    void OnTouchEnd();

private:
    std::shared_ptr<Common::DynamicLibrary> driver_library;
    int width = 0;
    int height = 0;
    bool portrait = false;
};

// ----- input -----------------------------------------------------------------------------------
namespace Pad {
void Init();
void Shutdown();
/// Param package strings bound to the 3DS buttons/sticks (engine:azios,…).
std::string ButtonParam(int az_button);
std::string StickParam(int az_stick);
std::string MotionParam();
void SetButton(int az_button, bool pressed);
void SetStick(int az_stick, float x, float y);
void SetMotion(float ax, float ay, float az, float gx, float gy, float gz);
void SetMotionRotation(int rotation);
void ReleaseAll();
} // namespace Pad

// ----- configuration ---------------------------------------------------------------------------
namespace Config {
/// Path of the ini file the Swift side writes (user_dir/config/ios-config.ini).
std::string Path();
/// Loads the ini into Settings::values (creating a default file if missing).
void Load();
} // namespace Config

// ----- jit -------------------------------------------------------------------------------------
AZJitStatus DetectJit();
/// The JIT mode the running game was started with (-1 when no game runs).
void SetSessionJit(AZJitStatus status);

// ----- keyboard applet -------------------------------------------------------------------------
void SetKeyboardCallback(AZKeyboardCallback cb, void* ctx);
void RegisterApplets();

// ----- multiplayer -----------------------------------------------------------------------------
namespace Multiplayer {
/// Called when the emulated system powers on/off so the room member's game info is kept fresh.
void OnGameStarted(const std::string& name, unsigned long long title_id);
void OnGameStopped();
} // namespace Multiplayer

// ----- global state ----------------------------------------------------------------------------
struct State {
    std::string user_dir;
    std::string vulkan_library_path;
    std::shared_ptr<Common::DynamicLibrary> vulkan_library;

    /// Held by the emulation thread while the renderer (re)initialises (System::Load, savestate
    /// loads). UI-thread entry points only ever try_lock it so the UI can never block on it.
    std::recursive_mutex surface_mutex;

    /// Latest surface handed over by the UI (guarded by info_mutex, never held for long).
    std::mutex info_mutex;
    void* surface = nullptr;
    int surface_width = 0;
    int surface_height = 0;
    bool surface_portrait = false;
    /// Set when the surface or the layout changed but could not be applied immediately.
    std::atomic_bool surface_dirty{false};
    /// A touch release that arrived while the renderer was busy; delivered by the emu thread.
    std::atomic_bool touch_release_pending{false};

    std::unique_ptr<EmuWindowApple> window;

    std::mutex run_mutex; ///< only one az_run_game at a time
    std::atomic_bool running{false};
    std::atomic_bool stop_requested{false};
    std::atomic_bool paused{false};
    std::mutex pause_mutex;
    std::condition_variable pause_cv;

    // Software renderer frames, copied on the emulation thread after each frame.
    std::mutex frame_mutex;
    std::vector<unsigned char> frame_pixels[2];
    int frame_width[2] = {0, 0};
    int frame_height[2] = {0, 0};
    std::atomic<uint64_t> frame_counter{0};
    std::atomic_bool software_renderer{false};

    std::mutex error_mutex;
    std::string last_error;

    bool initialized = false;
};

State& GetState();

} // namespace AzIOS
