// Reads user_dir/config/ios-config.ini (written by the Swift settings screen) into
// Settings::values. Keys are Azahar's own setting labels, so the file is easy to compare
// with a desktop qt-config.ini. Licensed under GPLv2 or any later version.

#include <INIReader.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#include "az_internal.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/filter.h"
#include "common/logging/log.h"
#include "common/settings.h"
#include "core/hle/service/service.h"

namespace AzIOS::Config {

namespace {

constexpr const char* kDefaultIni = R"([Core]
use_cpu_jit = true
cpu_clock_percentage = 100

[Renderer]
graphics_api = 2
use_hw_shader = true
use_shader_jit = true
shaders_accurate_mul = true
use_disk_shader_cache = true
async_shader_compilation = true
async_presentation = true
spirv_shader_gen = true
resolution_factor = 2
frame_limit = 100
use_vsync = true
texture_filter = 0
filter_mode = true
render_3d = 0
factor_3d = 0

[Layout]
layout_option = 0
portrait_layout_option = 0
swap_screen = false
upright_screen = false
large_screen_proportion = 4

[Audio]
audio_emulation = 0
enable_audio_stretching = true
volume = 1
output_type = 0
input_type = 1

[System]
is_new_3ds = true
lle_applets = false
region_value = -1

[Data Storage]
use_virtual_sd = true

[WebService]
web_api_url =
network_token =

[Miscellaneous]
log_filter = *:Info
)";

template <typename T, bool ranged>
void Read(INIReader& ini, const std::string& section, Settings::Setting<T, ranged>& setting) {
    if constexpr (std::is_same_v<T, bool>) {
        setting = ini.GetBoolean(section, setting.GetLabel(), setting.GetDefault());
    } else if constexpr (std::is_same_v<T, std::string>) {
        setting = ini.Get(section, setting.GetLabel(), setting.GetDefault());
    } else if constexpr (std::is_floating_point_v<T>) {
        setting = static_cast<T>(
            ini.GetReal(section, setting.GetLabel(), static_cast<double>(setting.GetDefault())));
    } else {
        setting = static_cast<T>(ini.GetInteger(section, setting.GetLabel(),
                                                static_cast<long>(setting.GetDefault())));
    }
}

void BindInput() {
    auto& profile = Settings::values.current_input_profile;
    for (int i = 0; i < Settings::NativeButton::NumButtons; ++i) {
        // AZButton is declared in the same order as Settings::NativeButton.
        profile.buttons[i] = Pad::ButtonParam(i);
    }
    for (int i = 0; i < Settings::NativeAnalog::NumAnalogs; ++i) {
        profile.analogs[i] = Pad::StickParam(i);
    }
    profile.motion_device = Pad::MotionParam();
    profile.touch_device = "engine:emu_window";
}

} // namespace

std::string Path() {
    return FileUtil::GetUserPath(FileUtil::UserPath::ConfigDir) + "ios-config.ini";
}

void Load() {
    const std::string path = Path();
    if (!FileUtil::Exists(path)) {
        FileUtil::CreateFullPath(path);
        FileUtil::WriteStringToFile(true, path, kDefaultIni);
    }

    std::string buffer;
    FileUtil::ReadFileToString(true, path, buffer);
    INIReader ini(buffer.c_str(), buffer.size());
    if (ini.ParseError() < 0) {
        LOG_ERROR(Config, "Could not parse {}, using defaults", path);
        buffer = kDefaultIni;
    }
    INIReader parsed(buffer.c_str(), buffer.size());
    auto& v = Settings::values;

    // Core
    Read(parsed, "Core", v.use_cpu_jit);
    Read(parsed, "Core", v.cpu_clock_percentage);

    // Renderer
    Read(parsed, "Renderer", v.graphics_api);
    Read(parsed, "Renderer", v.use_hw_shader);
    Read(parsed, "Renderer", v.use_shader_jit);
    Read(parsed, "Renderer", v.shaders_accurate_mul);
    Read(parsed, "Renderer", v.use_disk_shader_cache);
    Read(parsed, "Renderer", v.async_shader_compilation);
    Read(parsed, "Renderer", v.async_presentation);
    Read(parsed, "Renderer", v.spirv_shader_gen);
    Read(parsed, "Renderer", v.resolution_factor);
    Read(parsed, "Renderer", v.frame_limit);
    Read(parsed, "Renderer", v.use_vsync);
    Read(parsed, "Renderer", v.texture_filter);
    Read(parsed, "Renderer", v.filter_mode);
    Read(parsed, "Renderer", v.render_3d);
    Read(parsed, "Renderer", v.factor_3d);

    // Layout
    Read(parsed, "Layout", v.layout_option);
    Read(parsed, "Layout", v.portrait_layout_option);
    Read(parsed, "Layout", v.swap_screen);
    Read(parsed, "Layout", v.upright_screen);
    Read(parsed, "Layout", v.large_screen_proportion);

    // Audio
    Read(parsed, "Audio", v.audio_emulation);
    Read(parsed, "Audio", v.enable_audio_stretching);
    Read(parsed, "Audio", v.volume);
    Read(parsed, "Audio", v.output_type);
    Read(parsed, "Audio", v.input_type);

    // System
    Read(parsed, "System", v.is_new_3ds);
    Read(parsed, "System", v.lle_applets);
    Read(parsed, "System", v.region_value);
    Read(parsed, "Data Storage", v.use_virtual_sd);

    // Every HLE service module needs an entry, otherwise Service::Init() throws.
    for (const auto& service_module : Service::service_module_map) {
        v.lle_modules[service_module.name] =
            parsed.GetBoolean("Debugging", "LLE\\" + service_module.name, false);
    }
    Read(parsed, "System", v.enable_required_online_lle_modules);

    // Web service (lobby)
    Read(parsed, "WebService", v.web_api_url);
    Read(parsed, "WebService", v.network_token);

    // Logging
    Read(parsed, "Miscellaneous", v.log_filter);
    Common::Log::Filter filter;
    filter.ParseFilterString(v.log_filter.GetValue());
    Common::Log::SetGlobalFilter(filter);

#if !defined(__APPLE__)
    // Host-side unit tests have no GPU surface; use the software rasteriser.
    v.graphics_api = Settings::GraphicsAPI::Software;
#elif TARGET_OS_SIMULATOR
    // The iOS Simulator's Metal driver aborts on MoltenVK texel buffers (MTLSimBuffer
    // newTextureWithDescriptor), so the simulator always uses the software renderer.
    v.graphics_api = Settings::GraphicsAPI::Software;
#endif

    // JIT policy: never ask the core for JIT if the process cannot map executable pages,
    // otherwise dynarmic would crash on its first block.
    const AZJitStatus jit = DetectJit();
    if (jit == AZ_JIT_UNAVAILABLE || jit == AZ_JIT_DISABLED_BUILD) {
        v.use_cpu_jit = false;
        v.use_shader_jit = false;
    }
#if defined(__APPLE__)
    // The shader JIT is x86-64 only; there is nothing to gain on ARM.
    v.use_shader_jit = false;
#endif

    BindInput();
    LOG_INFO(Config, "Loaded {} (cpu_jit={}, api={})", path, v.use_cpu_jit.GetValue(),
             static_cast<int>(v.graphics_api.GetValue()));
}

} // namespace AzIOS::Config
