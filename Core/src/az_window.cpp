// EmuWindow for iOS: hands a CAMetalLayer to the Vulkan renderer (MoltenVK).
// Licensed under GPLv2 or any later version.

#include <algorithm>
#include <cmath>

#include "az_internal.h"
#include "common/dynamic_library/dynamic_library.h"
#include "common/logging/log.h"
#include "common/settings.h"

namespace AzIOS {

namespace {

/// The Vulkan renderer asks the graphics context for the driver library. On iOS the frontend
/// supplies the embedded MoltenVK so the core does not need to guess a dylib name.
class GraphicsContextApple final : public Frontend::GraphicsContext {
public:
    explicit GraphicsContextApple(std::shared_ptr<Common::DynamicLibrary> lib)
        : driver_library{std::move(lib)} {}

    std::shared_ptr<Common::DynamicLibrary> GetDriverLibrary() override {
        return driver_library;
    }

private:
    std::shared_ptr<Common::DynamicLibrary> driver_library;
};

Frontend::WindowSystemType SurfaceType() {
#if defined(__APPLE__)
    return Frontend::WindowSystemType::MacOS; // VK_EXT_metal_surface, used for iOS too
#else
    return Frontend::WindowSystemType::Headless;
#endif
}

} // namespace

EmuWindowApple::EmuWindowApple(std::shared_ptr<Common::DynamicLibrary> driver_library_)
    : Frontend::EmuWindow(false), driver_library{std::move(driver_library_)} {
    auto& st = GetState();
    std::scoped_lock lock{st.info_mutex};
    SetSurface(st.surface, st.surface_width, st.surface_height, st.surface_portrait);
}

EmuWindowApple::~EmuWindowApple() = default;

void EmuWindowApple::PollEvents() {
    NoteFrame();
}

bool EmuWindowApple::SetSurface(void* surface, int width_, int height_, bool is_portrait) {
    const bool changed = window_info.render_surface != surface || width != width_ ||
                         height != height_ || portrait != is_portrait;
    width = std::max(width_, 1);
    height = std::max(height_, 1);
    portrait = is_portrait;

    window_info.type = surface ? SurfaceType() : Frontend::WindowSystemType::Headless;
    window_info.render_surface = surface;
    window_info.render_surface_scale = 1.0f; // sizes are already in pixels

    RelayoutForCurrentSettings();
    return changed;
}

void EmuWindowApple::RelayoutForCurrentSettings() {
    UpdateCurrentFramebufferLayout(static_cast<unsigned>(width), static_cast<unsigned>(height),
                                   portrait);
}

std::unique_ptr<Frontend::GraphicsContext> EmuWindowApple::CreateSharedContext() const {
    return std::make_unique<GraphicsContextApple>(driver_library);
}

std::shared_ptr<Common::DynamicLibrary> EmuWindowApple::GetDriverLibrary() {
    return driver_library;
}

bool EmuWindowApple::OnTouchBegin(float x, float y) {
    return TouchPressed(static_cast<unsigned>(std::max(0.0f, std::round(x))),
                        static_cast<unsigned>(std::max(0.0f, std::round(y))));
}

void EmuWindowApple::OnTouchMove(float x, float y) {
    TouchMoved(static_cast<unsigned>(std::max(0.0f, std::round(x))),
               static_cast<unsigned>(std::max(0.0f, std::round(y))));
}

void EmuWindowApple::OnTouchEnd() {
    TouchReleased();
}

} // namespace AzIOS
