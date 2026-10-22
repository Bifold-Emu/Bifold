// AzaharCore C API: lifetime, game library and the emulation session.
// The run loop follows Azahar's Android frontend (src/android/app/src/main/jni/native.cpp).
// Licensed under GPLv2 or any later version.

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <future>
#include <map>
#include <mutex>
#include <vector>

#include <fmt/format.h>
#include <lodepng.h>
#ifdef __APPLE__
#include <atomic>
#include <cxxabi.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <malloc/malloc.h>
#include <mach/mach.h>
#include <os/lock.h>
#endif

#include "az_internal.h"
#include "common/common_paths.h"
#include "common/dynamic_library/dynamic_library.h"
#include "common/file_derived.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/log.h"
#include "common/scm_rev.h"
#include "common/settings.h"
#include "common/string_util.h"
#include "core/core.h"
#include "core/frontend/framebuffer_layout.h"
#include "core/file_sys/cia_container.h"
#include "core/file_sys/title_metadata.h"
#include "core/hle/kernel/kernel.h"
#include "core/hle/kernel/process.h"
#include "core/hle/kernel/shared_page.h"
#include "core/hle/service/am/am.h"
#include "core/hle/service/cfg/cfg.h"
#include "core/hle/service/fs/archive.h"
#include "core/loader/loader.h"
#include "core/loader/smdh.h"
#include "core/savestate.h"
#include "video_core/gpu.h"
#include "video_core/rasterizer_interface.h"
#include "video_core/renderer_base.h"
#include "video_core/renderer_software/renderer_software.h"

namespace AzIOS {

State& GetState() {
    static State state;
    return state;
}

char* DupString(const std::string& s) {
    char* out = static_cast<char*>(std::malloc(s.size() + 1));
    if (out) {
        std::memcpy(out, s.c_str(), s.size() + 1);
    }
    return out;
}

namespace {

AZLoadingCallback loading_cb = nullptr;
void* loading_ctx = nullptr;

void SetLastError(const std::string& err) {
    auto& st = GetState();
    std::scoped_lock lock{st.error_mutex};
    st.last_error = err;
}

AZResult MapResult(Core::System::ResultStatus r) {
    using R = Core::System::ResultStatus;
    switch (r) {
    case R::Success:
        return AZ_RESULT_SUCCESS;
    case R::ShutdownRequested:
        return AZ_RESULT_SHUTDOWN_REQUESTED;
    case R::ErrorGetLoader:
        return AZ_RESULT_ERROR_GET_LOADER;
    case R::ErrorSystemMode:
        return AZ_RESULT_ERROR_SYSTEM_MODE;
    case R::ErrorLoader:
        return AZ_RESULT_ERROR_LOADER;
    case R::ErrorLoader_ErrorEncrypted:
        return AZ_RESULT_ERROR_ENCRYPTED;
    case R::ErrorLoader_ErrorInvalidFormat:
        return AZ_RESULT_ERROR_INVALID_FORMAT;
    case R::ErrorLoader_ErrorGbaTitle:
        return AZ_RESULT_ERROR_GBA_TITLE;
    case R::ErrorSystemFiles:
        return AZ_RESULT_ERROR_SYSTEM_FILES;
    default:
        return AZ_RESULT_ERROR_OTHER;
    }
}

template <std::size_t N>
std::string FromUtf16(const std::array<char16_t, N>& arr) {
    std::size_t len = 0;
    while (len < N && arr[len] != u'\0') {
        ++len;
    }
    return Common::UTF16ToUTF8(std::u16string(arr.data(), len));
}

std::string ReadTitle(const Loader::SMDH& smdh, int language) {
    using Lang = Loader::SMDH::TitleLanguage;
    const auto pick = [&](Lang lang) { return FromUtf16(smdh.GetLongTitle(lang)); };
    std::string title = pick(static_cast<Lang>(std::clamp(language, 0, 11)));
    if (title.empty()) {
        title = pick(Lang::English);
    }
    if (title.empty()) {
        title = pick(Lang::Japanese);
    }
    // Long titles use '\n' between the name and subtitle.
    for (auto& c : title) {
        if (c == '\n') {
            c = ' ';
        }
    }
    return title;
}

void CopyField(char* dst, std::size_t cap, const std::string& src) {
    std::strncpy(dst, src.c_str(), cap - 1);
    dst[cap - 1] = '\0';
}

/// Copies the software renderer's screens into our own buffers (emulation thread only), so the UI
/// can read them without racing the renderer.
void CaptureSoftwareFrame() {
    auto& st = GetState();
    auto& system = Core::System::GetInstance();
    const auto& renderer = static_cast<SwRenderer::RendererSoftware&>(system.GPU().Renderer());
    const VideoCore::ScreenId ids[2] = {VideoCore::ScreenId::TopLeft, VideoCore::ScreenId::Bottom};
    std::scoped_lock lock{st.frame_mutex};
    for (int i = 0; i < 2; ++i) {
        const auto& info = renderer.Screen(ids[i]);
        if (info.pixels.empty()) {
            continue;
        }
        // The renderer stores the rotated LCD: the image is info.height wide, info.width tall.
        st.frame_width[i] = static_cast<int>(info.height);
        st.frame_height[i] = static_cast<int>(info.width);
        st.frame_pixels[i] = info.pixels;
    }
    ++st.frame_counter;
}

void WaitWhilePaused() {
    auto& st = GetState();
    // Mute while paused so no audio bleeds out.
    const float volume = Settings::values.volume.GetValue();
    Settings::values.volume = 0.0f;
    std::unique_lock lock{st.pause_mutex};
    st.pause_cv.wait(lock, [&] { return !st.paused || st.stop_requested; });
    Settings::values.volume = volume;
}

/// Applies the latest surface/layout to the window. Caller holds surface_mutex.
void ApplySurfaceLocked() {
    auto& st = GetState();
    if (!st.window) {
        return;
    }
    void* surface;
    int w, h;
    bool portrait;
    {
        std::scoped_lock lock{st.info_mutex};
        surface = st.surface;
        w = st.surface_width;
        h = st.surface_height;
        portrait = st.surface_portrait;
    }
    const bool changed = st.window->SetSurface(surface, w, h, portrait);
    auto& system = Core::System::GetInstance();
    if (changed && surface && system.IsPoweredOn()) {
        system.GPU().Renderer().NotifySurfaceChanged(false);
    }
}

/// From the UI thread: apply now if the emulation thread is not busy re-initialising the
/// renderer, otherwise leave it to the emulation loop (which checks surface_dirty every frame).
void RequestSurfaceUpdate() {
    auto& st = GetState();
    st.surface_dirty = true;
    std::unique_lock lock{st.surface_mutex, std::try_to_lock};
    if (lock.owns_lock()) {
        st.surface_dirty = false;
        ApplySurfaceLocked();
    }
}

void ApplyPendingSurfaceFromEmuThread() {
    auto& st = GetState();
    if (st.surface_dirty.exchange(false)) {
        std::scoped_lock lock{st.surface_mutex};
        ApplySurfaceLocked();
    }
    if (st.touch_release_pending.exchange(false)) {
        std::scoped_lock lock{st.surface_mutex};
        if (st.window) {
            st.window->OnTouchEnd();
        }
    }
}

} // namespace
} // namespace AzIOS

using namespace AzIOS;

extern "C" {

void az_free(void* ptr) {
    std::free(ptr);
}

bool az_init(const char* user_dir, const char* vulkan_library_path) {
    auto& st = GetState();
    if (st.initialized) {
        return true;
    }
    if (!user_dir || !*user_dir) {
        return false;
    }
    std::string dir = user_dir;
    if (dir.back() != '/') {
        dir += '/';
    }
    st.user_dir = dir;

    // Must happen before anything queries FileUtil::GetUserPath.
    FileUtil::SetUserPath(dir);
    FileUtil::CreateFullPath(FileUtil::GetUserPath(FileUtil::UserPath::ConfigDir));
    FileUtil::CreateFullPath(FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir));
    FileUtil::CreateFullPath(FileUtil::GetUserPath(FileUtil::UserPath::NANDDir));
    FileUtil::CreateFullPath(FileUtil::GetUserPath(FileUtil::UserPath::SysDataDir));

    Common::Log::Initialize();
    Common::Log::Start();
    LOG_INFO(Frontend, "AzaharCore for iOS starting, {} ({}-{})", Common::g_build_fullname,
             Common::g_scm_branch, Common::g_scm_desc);
    LOG_INFO(Frontend, "User directory: {}", dir);

    if (vulkan_library_path && *vulkan_library_path) {
        st.vulkan_library_path = vulkan_library_path;
        auto lib = std::make_shared<Common::DynamicLibrary>();
        if (lib->Load(st.vulkan_library_path)) {
            st.vulkan_library = lib;
            LOG_INFO(Frontend, "Loaded Vulkan driver {}", st.vulkan_library_path);
        } else {
            LOG_ERROR(Frontend, "Could not load Vulkan driver {}: {}", st.vulkan_library_path,
                      lib->GetLoadError());
        }
    }

    Pad::Init();
    Config::Load();
    st.initialized = true;
    return true;
}

void az_reload_settings(void) {
    Config::Load();
    auto& system = Core::System::GetInstance();
    if (system.IsPoweredOn()) {
        system.ApplySettings();
        RequestSurfaceUpdate();
    }
}

char* az_core_version(void) {
    return DupString(std::string("Azahar ") + Common::g_build_fullname);
}

bool az_get_game_info(const char* path, int language, AZGameInfo* out) {
    if (!path || !out) {
        return false;
    }
    std::memset(out, 0, sizeof(*out));
    auto loader = Loader::GetLoader(path);
    if (!loader) {
        return false;
    }

    u64 program_id = 0;
    auto result = loader->ReadProgramId(program_id);
    if (result == Loader::ResultStatus::ErrorNotImplemented) {
        program_id = 0; // 3DSX / ELF
        result = Loader::ResultStatus::Success;
    }
    out->title_id = program_id;
    CopyField(out->file_type, sizeof(out->file_type),
              Loader::GetFileTypeString(loader->GetFileType(), loader->IsFileCompressed()));

    std::vector<u8> smdh_data;
    const auto icon_result = loader->ReadIcon(smdh_data);
    out->encrypted = icon_result == Loader::ResultStatus::ErrorEncrypted ||
                     result == Loader::ResultStatus::ErrorEncrypted;
    out->valid = result == Loader::ResultStatus::Success;

    if (icon_result == Loader::ResultStatus::Success && Loader::IsValidSMDH(smdh_data)) {
        Loader::SMDH smdh;
        std::memcpy(&smdh, smdh_data.data(), sizeof(Loader::SMDH));
        CopyField(out->title, sizeof(out->title), ReadTitle(smdh, language));
        CopyField(out->publisher, sizeof(out->publisher), FromUtf16(smdh.titles[1].publisher));
        for (const auto region : smdh.GetRegions()) {
            out->region_mask |= 1u << static_cast<u32>(region);
        }
        const std::vector<u16> icon = smdh.GetIcon(true); // RGB565, linear 48x48
        if (icon.size() == 48 * 48) {
            for (std::size_t i = 0; i < icon.size(); ++i) {
                const u16 px = icon[i];
                const u32 r = ((px >> 11) & 0x1F) * 255 / 31;
                const u32 g = ((px >> 5) & 0x3F) * 255 / 63;
                const u32 b = (px & 0x1F) * 255 / 31;
                // Memory order R,G,B,A on little-endian.
                out->icon_rgba[i] = r | (g << 8) | (b << 16) | (0xFFu << 24);
            }
            out->has_icon = true;
        }
    }
    if (out->title[0] == '\0') {
        // Homebrew without SMDH: use the file name.
        std::string name = path;
        if (const auto slash = name.find_last_of('/'); slash != std::string::npos) {
            name = name.substr(slash + 1);
        }
        CopyField(out->title, sizeof(out->title), name);
    }
    return true;
}

int az_install_cia(const char* path, AZProgressCallback cb, void* ctx) {
    if (!path) {
        return 4;
    }
    // Azahar refuses NCCH-level encrypted content when installing from the frontend (only the
    // emulated system's own installs may decrypt). InstallCIA only notices that halfway through
    // and then reports "aborted"; check first so the user gets the real reason. ErrorInvalid is
    // ignored here because the check also rejects non-NCCH (DS) contents that do install fine.
    {
        bool compressed = false;
        if (Service::AM::CheckCIAToInstall(path, compressed, true) ==
            Service::AM::InstallStatus::ErrorEncrypted) {
            return 2;
        }
    }
    const auto status = Service::AM::InstallCIA(
        path, [cb, ctx](std::size_t done, std::size_t total) {
            if (cb) {
                cb(done, total, ctx);
            }
        });
    switch (status) {
    case Service::AM::InstallStatus::Success:
        return 0;
    case Service::AM::InstallStatus::ErrorEncrypted:
        return 2;
    case Service::AM::InstallStatus::ErrorInvalid:
        return 3;
    case Service::AM::InstallStatus::ErrorFileNotFound:
        return 4;
    case Service::AM::InstallStatus::ErrorAborted:
        return 5;
    default:
        return 1;
    }
}

namespace {
std::string SdmcTitleRoot() {
    return FileUtil::GetUserPath(FileUtil::UserPath::SDMCDir) +
           "Nintendo 3DS/00000000000000000000000000000000/00000000000000000000000000000000/title/";
}

std::string JsonEscape(const std::string& in) {
    std::string esc;
    for (char c : in) {
        if (c == '"' || c == '\\') {
            esc += '\\';
        }
        esc += c;
    }
    return esc;
}
} // namespace

extern "C" AZTitleKind az_title_kind(uint64_t title_id) {
    switch (title_id >> 32) {
    case 0x00040000:
    case 0x00040002:
        return AZ_TITLE_APPLICATION;
    case 0x0004000E:
        return AZ_TITLE_UPDATE;
    case 0x0004008C:
        return AZ_TITLE_DLC;
    default:
        return AZ_TITLE_OTHER;
    }
}

extern "C" bool az_get_cia_info(const char* path, AZCIAInfo* out) {
    if (!path || !out) {
        return false;
    }
    std::memset(out, 0, sizeof(*out));
    // Like Service::AM::GetCIAInfos, but also reads compressed (.zcia / Z3DS) files.
    std::unique_ptr<FileUtil::IOFileBase> file = std::make_unique<FileUtil::IOFile>(path, "rb");
    if (!file->IsOpen()) {
        return false;
    }
    if (FileUtil::Z3DSReadIOFile::GetUnderlyingFileMagic(file.get()) != std::nullopt) {
        file = std::make_unique<FileUtil::Z3DSReadIOFile>(std::move(file));
    }
    FileSys::CIAContainer container;
    if (container.Load(file.get()) != Loader::ResultStatus::Success) {
        return false;
    }
    const auto& tmd = container.GetTitleMetadata();
    out->title_id = tmd.GetTitleID();
    out->version = tmd.GetTitleVersion();
    out->kind = az_title_kind(out->title_id);
    if (const auto& smdh = container.GetSMDH()) {
        const auto name = smdh->GetShortTitle(Loader::SMDH::TitleLanguage::English);
        const std::u16string u16(name.data(), std::char_traits<char16_t>::length(name.data()));
        const std::string utf8 = Common::UTF16ToUTF8(u16);
        std::strncpy(out->title, utf8.c_str(), sizeof(out->title) - 1);
    }
    return true;
}

extern "C" char* az_list_installed_addons(void) {
    std::string json = "[";
    bool first = true;
    for (const auto& [high, kind] : {std::pair<u64, const char*>{0x0004000E, "update"},
                                     std::pair<u64, const char*>{0x0004008C, "dlc"}}) {
        const std::string dir = SdmcTitleRoot() + fmt::format("{:08x}/", high);
        FileUtil::ForeachDirectoryEntry(
            nullptr, dir, [&](u64*, const std::string&, const std::string& name) {
                if (name.size() != 8 || !FileUtil::IsDirectory(dir + name)) {
                    return true;
                }
                const u64 tid = (high << 32) | std::strtoull(name.c_str(), nullptr, 16);
                FileSys::TitleMetadata tmd;
                if (tmd.Load(Service::AM::GetTitleMetadataPath(Service::FS::MediaType::SDMC,
                                                               tid)) !=
                    Loader::ResultStatus::Success) {
                    return true; // half-installed or removed
                }
                json += first ? "" : ",";
                first = false;
                json += fmt::format("{{\"title_id\":{},\"kind\":\"{}\",\"version\":{}}}", tid,
                                    kind, tmd.GetTitleVersion());
                return true;
            });
    }
    json += "]";
    return AzIOS::DupString(json);
}

char* az_list_installed_titles(void) {
    std::vector<std::pair<std::string, u64>> games;
    FileUtil::DirectoryEntryCallable scan;
    scan = [&](u64*, const std::string& directory, const std::string& virtual_name) {
        std::string path = directory + virtual_name;
        if (FileUtil::IsDirectory(path)) {
            path += '/';
            FileUtil::ForeachDirectoryEntry(nullptr, path, scan);
            return true;
        }
        if (auto loader = Loader::GetLoader(path)) {
            bool executable = false;
            if (loader->IsExecutable(executable) == Loader::ResultStatus::Success && executable) {
                u64 id = 0;
                loader->ReadProgramId(id);
                games.emplace_back(path, id);
            }
        }
        return true;
    };
    // Applications and demos only: updates (0004000E) and DLC (0004008C) are not bootable on
    // their own; the loader overlays an installed update automatically when the base boots.
    scan(nullptr, "", SdmcTitleRoot() + "00040000");
    scan(nullptr, "", SdmcTitleRoot() + "00040002");
    std::string json = "[";
    for (std::size_t i = 0; i < games.size(); ++i) {
        const std::string esc = JsonEscape(games[i].first);
        json += (i ? "," : "");
        json += "{\"path\":\"" + esc + "\",\"title_id\":" + std::to_string(games[i].second) + "}";
    }
    json += "]";
    return DupString(json);
}

void az_set_loading_callback(AZLoadingCallback cb, void* ctx) {
    loading_cb = cb;
    loading_ctx = ctx;
}

void az_set_surface(void* surface, int width_px, int height_px, bool is_portrait) {
    auto& st = GetState();
    {
        std::scoped_lock lock{st.info_mutex};
        st.surface = surface;
        st.surface_width = width_px;
        st.surface_height = height_px;
        st.surface_portrait = is_portrait;
    }
    RequestSurfaceUpdate();
}

AZResult az_run_game(const char* path) {
    auto& st = GetState();
    if (!st.initialized || !path) {
        return AZ_RESULT_ERROR_OTHER;
    }
    std::unique_lock run_lock{st.run_mutex, std::try_to_lock};
    if (!run_lock.owns_lock()) {
        SetLastError("A game is already running");
        return AZ_RESULT_ERROR_OTHER;
    }
    SetLastError("");

    auto& system = Core::System::GetInstance();
    Config::Load();

#if defined(__APPLE__)
    {
        std::scoped_lock lock{st.info_mutex};
        if (!st.surface) {
            SetLastError("No rendering surface");
            return AZ_RESULT_ERROR_NO_SURFACE;
        }
    }
#endif

    // Savestate loading re-runs System::Init (GPU re-init) on the emulation thread; keep the
    // surface stable while that happens, like the Android frontend does.
    system.RegisterOnInitCallback([](bool init_start) {
        auto& s = GetState();
        if (init_start) {
            s.surface_mutex.lock();
        } else {
            s.surface_mutex.unlock();
        }
    });

    std::unique_lock surface_lock{st.surface_mutex};
    st.window = std::make_unique<EmuWindowApple>(st.vulkan_library);

    u64 program_id = 0;
    FileUtil::SetCurrentRomPath(path);
    auto app_loader = Loader::GetLoader(path);
    if (app_loader) {
        app_loader->ReadProgramId(program_id);
        system.RegisterAppLoaderEarly(app_loader);
    }
    system.ApplySettings();
    Settings::LogSettings();
    RegisterApplets();
    system.RegisterMicPermissionCheck([] { return false; });

    st.stop_requested = false;
    st.paused = false;
    st.surface_dirty = false;
    Core::System::ResultStatus load_result = Core::System::ResultStatus::ErrorLoader;
    try {
        load_result = system.Load(*st.window, path, nullptr);
    } catch (const std::bad_alloc&) {
        // On iOS 26 this means the debugger-provided JIT arena is too small/unavailable.
        SetLastError("Out of JIT memory: increase the JIT arena in Settings or disable JIT");
        load_result = Core::System::ResultStatus::ErrorUnknown;
    } catch (const std::exception& e) {
        SetLastError(e.what());
        load_result = Core::System::ResultStatus::ErrorUnknown;
    }
    surface_lock.unlock();
    ApplyPendingSurfaceFromEmuThread();

    if (load_result != Core::System::ResultStatus::Success) {
        if (!system.GetStatusDetails().empty()) {
            SetLastError(system.GetStatusDetails());
        }
        LOG_CRITICAL(Frontend, "Failed to load {}: {}", path, static_cast<u32>(load_result));
        system.Shutdown();
        std::scoped_lock lock{st.surface_mutex};
        st.window.reset();
        return MapResult(load_result);
    }

    st.running = true;
    // What this session runs with: the debugger that granted a JIT region may detach later,
    // after which DetectJit() alone would report "unavailable" while the JIT keeps running.
    SetSessionJit(Settings::values.use_cpu_jit.GetValue() ? DetectJit() : AZ_JIT_UNAVAILABLE);
    st.software_renderer =
        Settings::values.graphics_api.GetValue() == Settings::GraphicsAPI::Software;
    st.frame_counter = 0;
    system.GPU().ApplyPerProgramSettings(program_id);
    if (loading_cb) {
        loading_cb(0, 0, 0, loading_ctx);
    }
    system.GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(
        st.stop_requested,
        [](VideoCore::LoadCallbackStage stage, std::size_t value, std::size_t total,
           const std::string&) {
            if (loading_cb) {
                loading_cb(static_cast<int>(stage), value, total, loading_ctx);
            }
        });
    if (loading_cb) {
        loading_cb(static_cast<int>(VideoCore::LoadCallbackStage::Complete), 0, 0, loading_ctx);
    }

    {
        std::string title;
        AZGameInfo info;
        if (az_get_game_info(path, 1, &info)) {
            title = info.title;
        }
        Multiplayer::OnGameStarted(title, program_id);
    }

    system.RegisterCoreLoopThreadId();
    AZResult final_result = AZ_RESULT_SUCCESS;
    while (!st.stop_requested) {
        if (st.paused) {
            WaitWhilePaused();
            continue;
        }
        ApplyPendingSurfaceFromEmuThread();
        Core::System::ResultStatus result;
        try {
            result = system.RunLoop();
        } catch (const std::bad_alloc&) {
            SetLastError("Out of JIT memory: increase the JIT arena in Settings or disable JIT");
            final_result = AZ_RESULT_ERROR_OTHER;
            break;
        }
        if (result == Core::System::ResultStatus::Success) {
            if (st.software_renderer) {
                // RunLoop returns several times per emulated frame; copy at most ~120×/s.
                static thread_local auto last_capture = std::chrono::steady_clock::time_point{};
                const auto now = std::chrono::steady_clock::now();
                if (now - last_capture >= std::chrono::milliseconds(8)) {
                    last_capture = now;
                    CaptureSoftwareFrame();
                }
            }
            continue;
        }
        if (result == Core::System::ResultStatus::ShutdownRequested) {
            final_result = AZ_RESULT_SHUTDOWN_REQUESTED;
        } else {
            SetLastError(system.GetStatusDetails());
            final_result = MapResult(result);
            LOG_CRITICAL(Frontend, "Core error {}: {}", static_cast<u32>(result),
                         system.GetStatusDetails());
        }
        break;
    }

    Multiplayer::OnGameStopped();
    Pad::ReleaseAll();
    {
        std::scoped_lock lock{st.surface_mutex};
        system.Shutdown();
        st.window.reset();
    }
    st.running = false;
    st.software_renderer = false;
    st.paused = false;
    SetSessionJit(static_cast<AZJitStatus>(-1));
    return final_result;
}

void az_pause(bool paused) {
    auto& st = GetState();
    {
        std::scoped_lock lock{st.pause_mutex};
        st.paused = paused;
    }
    if (paused) {
        Pad::ReleaseAll();
    }
    st.pause_cv.notify_all();
}

bool az_is_paused(void) {
    return GetState().paused;
}

void az_stop(void) {
    auto& st = GetState();
    {
        std::scoped_lock lock{st.pause_mutex};
        st.stop_requested = true;
        st.paused = false;
    }
    {
        // The UI tears its CAMetalLayer down right after stopping; never hand that pointer to a
        // later session. (The running renderer keeps its own reference through MoltenVK.)
        std::scoped_lock lock{st.info_mutex};
        st.surface = nullptr;
    }
    st.pause_cv.notify_all();
}

bool az_is_running(void) {
    return GetState().running;
}

uint64_t az_running_title_id(void) {
    auto& system = Core::System::GetInstance();
    if (!system.IsPoweredOn()) {
        return 0;
    }
    u64 id = 0;
    system.GetAppLoader().ReadProgramId(id);
    return id;
}

char* az_last_error_details(void) {
    auto& st = GetState();
    std::scoped_lock lock{st.error_mutex};
    return DupString(st.last_error);
}

bool az_get_perf_stats(AZPerfStats* out) {
    auto& system = Core::System::GetInstance();
    if (!out || !system.IsPoweredOn()) {
        return false;
    }
    const auto r = system.GetAndResetPerfStats();
    out->system_fps = r.system_fps;
    out->game_fps = r.game_fps;
    out->emulation_speed = r.emulation_speed;
    out->frametime_ms = r.system_fps > 0.0 ? 1000.0 / r.system_fps : 0.0;
    return true;
}

void az_set_speed_override(double percent) {
    if (percent > 0.0) {
        Settings::temporary_frame_limit = percent;
        Settings::is_temporary_frame_limit = true;
    } else {
        Settings::is_temporary_frame_limit = false;
    }
}

void az_save_state(int slot) {
    Core::System::GetInstance().SendSignal(Core::System::Signal::Save, static_cast<u32>(slot));
}

void az_load_state(int slot) {
    Core::System::GetInstance().SendSignal(Core::System::Signal::Load, static_cast<u32>(slot));
}

char* az_list_save_states(void) {
    auto& system = Core::System::GetInstance();
    if (!system.IsPoweredOn()) {
        return DupString("[]");
    }
    u64 title_id = 0;
    if (system.GetAppLoader().ReadProgramId(title_id) != Loader::ResultStatus::Success) {
        return DupString("[]");
    }
    const auto states = Core::ListSaveStates(title_id, system.Movie().GetCurrentMovieID());
    std::string json = "[";
    for (std::size_t i = 0; i < states.size(); ++i) {
        json += (i ? "," : "");
        json += "{\"slot\":" + std::to_string(states[i].slot) +
                ",\"time\":" + std::to_string(states[i].time) + "}";
    }
    json += "]";
    return DupString(json);
}

namespace {
/// The software renderer never services RendererBase::RequestScreenshot (only the Vulkan and
/// OpenGL renderers do, when they present), so a request would just time out. Build the image
/// from the frames the frontend already captures for display instead: top screen above the
/// bottom one, centred, like the default layout the hardware renderers use.
bool SoftwareScreenshot(const char* path) {
    auto& st = GetState();
    std::vector<u8> rgba;
    u32 w = 0, h = 0;
    {
        std::scoped_lock lock{st.frame_mutex};
        const int tw = st.frame_width[0], th = st.frame_height[0];
        const int bw = st.frame_width[1], bh = st.frame_height[1];
        const bool has_top = !st.frame_pixels[0].empty() && tw > 0 && th > 0;
        const bool has_bottom = !st.frame_pixels[1].empty() && bw > 0 && bh > 0;
        if (!has_top && !has_bottom) {
            return false;
        }
        w = static_cast<u32>(std::max(has_top ? tw : 0, has_bottom ? bw : 0));
        h = static_cast<u32>((has_top ? th : 0) + (has_bottom ? bh : 0));
        rgba.assign(static_cast<std::size_t>(w) * h * 4, 0);
        for (std::size_t i = 3; i < rgba.size(); i += 4) {
            rgba[i] = 0xFF; // opaque black around the narrower bottom screen
        }
        u32 y0 = 0;
        for (int screen = 0; screen < 2; ++screen) {
            const int sw = st.frame_width[screen], sh = st.frame_height[screen];
            const auto& px = st.frame_pixels[screen];
            if (px.empty() || sw <= 0 || sh <= 0 ||
                px.size() < static_cast<std::size_t>(sw) * sh * 4) {
                continue;
            }
            const u32 x0 = (w - static_cast<u32>(sw)) / 2;
            for (int y = 0; y < sh; ++y) {
                const u8* src = px.data() + static_cast<std::size_t>(y) * sw * 4;
                u8* dst = rgba.data() + ((static_cast<std::size_t>(y0) + y) * w + x0) * 4;
                for (int x = 0; x < sw; ++x) {
                    dst[x * 4 + 0] = src[x * 4 + 0];
                    dst[x * 4 + 1] = src[x * 4 + 1];
                    dst[x * 4 + 2] = src[x * 4 + 2];
                    dst[x * 4 + 3] = 0xFF;
                }
            }
            y0 += static_cast<u32>(sh);
        }
    }
    return lodepng::encode(path, rgba, w, h) == 0;
}
} // namespace

bool az_screenshot(const char* path) {
    auto& system = Core::System::GetInstance();
    if (!path || !system.IsPoweredOn()) {
        return false;
    }
    if (GetState().software_renderer) {
        return SoftwareScreenshot(path);
    }
    auto& renderer = system.GPU().Renderer();
    const u32 scale = renderer.GetResolutionScaleFactor();
    const auto layout = Layout::FrameLayoutFromResolutionScale(scale, false);
    // The renderer fills the buffer asynchronously; share ownership so a timeout cannot leave
    // it writing into freed memory.
    auto bgra_ptr = std::make_shared<std::vector<u8>>(static_cast<std::size_t>(layout.width) *
                                                      layout.height * 4);
    auto promise = std::make_shared<std::promise<bool>>();
    auto future = promise->get_future();
    renderer.RequestScreenshot(
        bgra_ptr->data(), [promise, bgra_ptr](bool invert_y) { promise->set_value(invert_y); },
        layout);
    if (future.wait_for(std::chrono::seconds(2)) != std::future_status::ready) {
        return false;
    }
    const bool invert_y = future.get();
    const std::vector<u8>& bgra = *bgra_ptr;
    const u32 w = layout.width, h = layout.height;
    std::vector<u8> rgba(bgra.size());
    for (u32 y = 0; y < h; ++y) {
        const u32 src_y = invert_y ? (h - 1 - y) : y;
        for (u32 x = 0; x < w; ++x) {
            const u8* s = &bgra[(static_cast<std::size_t>(src_y) * w + x) * 4];
            u8* d = &rgba[(static_cast<std::size_t>(y) * w + x) * 4];
            d[0] = s[2];
            d[1] = s[1];
            d[2] = s[0];
            d[3] = 0xFF;
        }
    }
    return lodepng::encode(path, rgba, w, h) == 0;
}

#ifdef __APPLE__
namespace {
// Filled while every malloc zone is locked, so it must not allocate.
struct HeapScan {
    static constexpr std::size_t kMax = 8192;
    std::array<std::size_t, kMax> big{};
    std::size_t big_count = 0;
    std::size_t big_dropped = 0;
    std::size_t small_bytes = 0;
    std::size_t small_count = 0;
};
HeapScan g_heap_scan;

kern_return_t HeapReader(task_t, vm_address_t address, vm_size_t, void** local) {
    *local = reinterpret_cast<void*>(address);
    return KERN_SUCCESS;
}

void HeapRecorder(task_t, void* context, unsigned, vm_range_t* ranges, unsigned count) {
    auto* scan = static_cast<HeapScan*>(context);
    for (unsigned i = 0; i < count; ++i) {
        const std::size_t size = ranges[i].size;
        if (size >= 512 * 1024) {
            if (scan->big_count < HeapScan::kMax) {
                scan->big[scan->big_count++] = size;
            } else {
                ++scan->big_dropped;
            }
        } else {
            scan->small_bytes += size;
            ++scan->small_count;
        }
    }
}
} // namespace

// Big-allocation tracker: hooks libmalloc's malloc_logger (the hook MallocStackLogging uses)
// and remembers the backtrace of each large block until it is freed. Debug builds only.
namespace {
typedef void(MallocLogger)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                           uintptr_t result, uint32_t skip);
constexpr uint32_t kLogAllocate = 2, kLogDeallocate = 4, kLogHasZone = 8;
struct BigAlloc {
    uintptr_t address;
    std::size_t size;
    int frames;
    void* stack[20];
};
constexpr int kMaxBig = 512;
BigAlloc g_big[kMaxBig];
int g_big_count = 0;
std::size_t g_big_min = SIZE_MAX;
os_unfair_lock g_big_lock = OS_UNFAIR_LOCK_INIT;
MallocLogger* g_previous_logger = nullptr;

void ForgetBig(uintptr_t address) {
    for (int i = 0; i < g_big_count; ++i) {
        if (g_big[i].address == address) {
            g_big[i] = g_big[--g_big_count];
            return;
        }
    }
}

void BigLogger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
               uint32_t skip) {
    if (g_previous_logger) {
        g_previous_logger(type, arg1, arg2, arg3, result, skip);
    }
    // Must not allocate: we are inside malloc/free. backtrace() and the unfair lock do not.
    if (!(type & kLogHasZone)) {
        return;
    }
    std::size_t size = 0;
    uintptr_t freed = 0;
    if ((type & kLogAllocate) && (type & kLogDeallocate)) { // realloc: arg2 old, arg3 new size
        freed = arg2;
        size = arg3;
    } else if (type & kLogAllocate) {
        size = arg2;
    } else if (type & kLogDeallocate) {
        freed = arg2;
    }
    BigAlloc entry{};
    const bool track = (type & kLogAllocate) && result && size >= g_big_min;
    if (track) {
        entry.address = result;
        entry.size = size;
        entry.frames = backtrace(entry.stack, 20);
    }
    if (freed || track) {
        os_unfair_lock_lock(&g_big_lock);
        if (freed) {
            ForgetBig(freed);
        }
        if (track && g_big_count < kMaxBig) {
            g_big[g_big_count++] = entry;
        }
        os_unfair_lock_unlock(&g_big_lock);
    }
}

std::string Symbolize(void* pc) {
    Dl_info info{};
    if (!dladdr(pc, &info) || !info.dli_sname) {
        return fmt::format("{}", pc);
    }
    int status = 0;
    char* demangled = abi::__cxa_demangle(info.dli_sname, nullptr, nullptr, &status);
    std::string name = status == 0 && demangled ? demangled : info.dli_sname;
    std::free(demangled);
    if (name.size() > 90) {
        name = name.substr(0, 90);
    }
    return name;
}
} // namespace

void az_debug_track_big_allocs(size_t min_bytes) {
    auto** logger = reinterpret_cast<MallocLogger**>(dlsym(RTLD_DEFAULT, "malloc_logger"));
    if (!logger) {
        return;
    }
    os_unfair_lock_lock(&g_big_lock);
    g_big_min = min_bytes;
    os_unfair_lock_unlock(&g_big_lock);
    if (*logger != BigLogger) {
        g_previous_logger = *logger;
        *logger = BigLogger;
    }
}

char* az_debug_heap(void) {
    vm_address_t* zones = nullptr;
    unsigned zone_count = 0;
    if (malloc_get_all_zones(mach_task_self(), HeapReader, &zones, &zone_count) != KERN_SUCCESS) {
        return AzIOS::DupString("malloc_get_all_zones failed");
    }
    // Copy the zone list first: the scan below must not allocate.
    std::vector<malloc_zone_t*> list;
    for (unsigned i = 0; i < zone_count; ++i) {
        list.push_back(reinterpret_cast<malloc_zone_t*>(zones[i]));
    }
    static std::mutex scan_mutex;
    std::scoped_lock scan_lock{scan_mutex};
    g_heap_scan = HeapScan{};
    for (auto* zone : list) {
        if (!zone || !zone->introspect || !zone->introspect->enumerator) {
            continue;
        }
        zone->introspect->force_lock(zone);
        zone->introspect->enumerator(mach_task_self(), &g_heap_scan, MALLOC_PTR_IN_USE_RANGE_TYPE,
                                     reinterpret_cast<vm_address_t>(zone), HeapReader,
                                     HeapRecorder);
        zone->introspect->force_unlock(zone);
    }
    std::map<std::size_t, std::size_t> by_size;
    std::size_t big_bytes = 0;
    for (std::size_t i = 0; i < g_heap_scan.big_count; ++i) {
        // Group by size rounded to 64 KiB so near-identical blocks land together.
        const std::size_t rounded = (g_heap_scan.big[i] + 0xFFFF) & ~std::size_t{0xFFFF};
        ++by_size[rounded];
        big_bytes += g_heap_scan.big[i];
    }
    std::vector<std::pair<std::size_t, std::size_t>> rows(by_size.begin(), by_size.end());
    std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) {
        return a.first * a.second > b.first * b.second;
    });
    std::string out = fmt::format("processes={} big={}MB/{} small={}MB/{}",
                                  Kernel::DebugLiveProcessCount(), big_bytes >> 20,
                                  g_heap_scan.big_count, g_heap_scan.small_bytes >> 20,
                                  g_heap_scan.small_count);
    if (g_heap_scan.big_dropped) {
        out += fmt::format(" dropped={}", g_heap_scan.big_dropped);
    }
    for (std::size_t i = 0; i < rows.size() && i < 16; ++i) {
        out += fmt::format(" {}K*{}", rows[i].first >> 10, rows[i].second);
    }
    // Where the tracked big blocks that are still alive were allocated.
    std::vector<BigAlloc> live;
    os_unfair_lock_lock(&g_big_lock);
    live.assign(g_big, g_big + g_big_count);
    os_unfair_lock_unlock(&g_big_lock);
    std::sort(live.begin(), live.end(),
              [](const BigAlloc& a, const BigAlloc& b) { return a.size > b.size; });
    for (const auto& b : live) {
        out += fmt::format("\n  {}K @{:x}:", b.size >> 10, b.address);
        for (int f = 2; f < b.frames && f < 14; ++f) {
            out += " < " + Symbolize(b.stack[f]);
        }
    }
    return AzIOS::DupString(out);
}
#else
char* az_debug_heap(void) {
    return AzIOS::DupString(fmt::format("processes={}", Kernel::DebugLiveProcessCount()));
}
void az_debug_track_big_allocs(size_t) {}
#endif

bool az_is_software_renderer(void) {
    return GetState().software_renderer;
}

uint64_t az_get_software_frame(int screen, uint8_t* rgba, int capacity, int* width, int* height) {
    auto& st = GetState();
    if (screen < 0 || screen > 1) {
        return 0;
    }
    std::scoped_lock lock{st.frame_mutex};
    if (width) {
        *width = st.frame_width[screen];
    }
    if (height) {
        *height = st.frame_height[screen];
    }
    const auto& px = st.frame_pixels[screen];
    if (rgba && !px.empty() && capacity >= static_cast<int>(px.size())) {
        std::memcpy(rgba, px.data(), px.size());
    }
    return px.empty() ? 0 : st.frame_counter.load();
}

bool az_get_screen_rects(AZScreenRect* top, AZScreenRect* bottom) {
    auto& st = GetState();
    std::unique_lock lock{st.surface_mutex, std::try_to_lock};
    if (!lock.owns_lock() || !st.window) {
        return false;
    }
    const auto& layout = st.window->GetFramebufferLayout();
    const auto fill = [](AZScreenRect* out, const Common::Rectangle<u32>& r, bool enabled) {
        if (!out) {
            return;
        }
        out->x = static_cast<float>(r.left);
        out->y = static_cast<float>(r.top);
        out->width = static_cast<float>(r.GetWidth());
        out->height = static_cast<float>(r.GetHeight());
        out->enabled = enabled;
    };
    fill(top, layout.top_screen, layout.top_screen_enabled);
    fill(bottom, layout.bottom_screen, layout.bottom_screen_enabled);
    return true;
}

void az_swap_screens(bool swapped) {
    Settings::values.swap_screen = swapped;
    RequestSurfaceUpdate();
}

void az_set_layout(int layout, bool is_portrait) {
    using L = Settings::LayoutOption;
    L option = L::Default;
    switch (layout) {
    case 1:
        option = L::SingleScreen;
        break;
    case 2:
        option = L::LargeScreen;
        break;
    case 3:
        option = L::SideScreen;
        break;
    case 4:
        option = L::HybridScreen;
        break;
    default:
        option = L::Default;
        break;
    }
    Settings::values.layout_option = option;
    auto& st = GetState();
    {
        std::scoped_lock lock{st.info_mutex};
        st.surface_portrait = is_portrait;
    }
    RequestSurfaceUpdate();
}

void az_button(AZButton button, bool pressed) {
    Pad::SetButton(static_cast<int>(button), pressed);
}

void az_stick(AZStick stick, float x, float y) {
    Pad::SetStick(static_cast<int>(stick), x, y);
}

void az_release_all_input(void) {
    Pad::ReleaseAll();
}

bool az_touch_begin(float x, float y) {
    auto& st = GetState();
    std::unique_lock lock{st.surface_mutex, std::try_to_lock};
    return lock.owns_lock() && st.window && st.window->OnTouchBegin(x, y);
}

void az_touch_move(float x, float y) {
    auto& st = GetState();
    std::unique_lock lock{st.surface_mutex, std::try_to_lock};
    if (lock.owns_lock() && st.window) {
        st.window->OnTouchMove(x, y);
    }
}

void az_touch_end(void) {
    auto& st = GetState();
    // Must not be dropped (a lost release would leave the stylus "down"), but it is cheap to wait
    // here only when no renderer re-init is in progress; otherwise retry from the emu thread.
    std::unique_lock lock{st.surface_mutex, std::try_to_lock};
    if (!lock.owns_lock()) {
        st.touch_release_pending = true;
        return;
    }
    if (st.window) {
        st.window->OnTouchEnd();
    }
}

void az_motion(float ax, float ay, float az, float gx, float gy, float gz) {
    Pad::SetMotion(ax, ay, az, gx, gy, gz);
}

void az_set_motion_orientation(int rotation) {
    Pad::SetMotionRotation(rotation);
}

char* az_get_console_username(void) {
    return DupString(Service::CFG::GetUsername(Core::System::GetInstance()));
}

void az_set_console_username(const char* name) {
    if (!name) {
        return;
    }
    auto& system = Core::System::GetInstance();
    if (system.IsPoweredOn()) {
        return; // only change the config savegame while no game is running
    }
    auto cfg = std::make_shared<Service::CFG::Module>(system);
    cfg->SetUsername(Common::UTF8ToUTF16(name));
    cfg->UpdateConfigNANDSavegame();
}

} // extern "C"

int64_t az_debug_console_clock_offset_ms(void) {
    auto& system = Core::System::GetInstance();
    if (!system.IsPoweredOn()) {
        return INT64_MIN;
    }
    const s64 console = static_cast<s64>(system.Kernel().GetSharedPageHandler().GetSystemTimeSince2000());
    // Host local time since 2000-01-01 00:00 local, computed like SharedPage::GetInitTime does.
    auto now = std::chrono::system_clock::now();
    const std::time_t now_t = std::chrono::system_clock::to_time_t(now);
    if (const std::tm* tm = std::localtime(&now_t); tm && tm->tm_isdst > 0) {
        now += std::chrono::hours(1);
    }
    std::tm epoch{};
    epoch.tm_mday = 1;
    epoch.tm_year = 100;
    const s64 host = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() -
                     static_cast<s64>(std::mktime(&epoch)) * 1000;
    return console - host;
}

