// Host-side test driver for AzaharCore (runs on Linux/macOS, no GPU needed).
//
//   azios_test info  <file>
//   azios_test boot  <elf> <seconds> <jit 0|1>     – boots a program, checks it runs at speed
//   azios_test exit  <elf>                         – program calls svcExitProcess, must return
//   azios_test host  <port> <nick> <seconds> [lobby_url token]
//   azios_test join  <addr> <port> <nick> <chat message> <seconds>
//   azios_test lobby <url>
//   azios_test savestate <elf>                     – save state, load it three times, keep running
//
// User directory: $AZ_TEST_USERDIR (default /tmp/azios-test-user).

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include "AzaharCore.h"
#include "common/file_util.h"
#include "common/zstd_compression.h"
#include "common/settings.h"
#include "core/frontend/input.h"

namespace {

std::string UserDir() {
    const char* d = std::getenv("AZ_TEST_USERDIR");
    return d ? d : "/tmp/azios-test-user";
}

void WriteIni(bool jit) {
    const std::string dir = UserDir() + "/config";
    std::system(("mkdir -p '" + dir + "'").c_str());
    std::ofstream f(dir + "/ios-config.ini");
    f << "[Core]\nuse_cpu_jit = " << (jit ? "true" : "false") << "\n"
      << "[Renderer]\ngraphics_api = 0\nresolution_factor = 1\nframe_limit = 100\n"
      << "[Audio]\noutput_type = 1\ninput_type = 1\n"
      << "[System]\nlle_applets = false\n"
      << "[Miscellaneous]\nlog_filter = *:Warning\n";
}

bool Init() {
    if (!az_init(UserDir().c_str(), nullptr)) {
        std::fprintf(stderr, "az_init failed\n");
        return false;
    }
    return true;
}

std::atomic_int chat_count{0};
std::atomic_int join_count{0};

void MpEvent(AZMultiplayerEvent ev, const char* msg, void*) {
    std::printf("[event %d] %s\n", static_cast<int>(ev), msg);
    std::fflush(stdout);
    if (ev == AZ_MP_EVENT_CHAT) {
        ++chat_count;
    }
    if (ev == AZ_MP_EVENT_MEMBER_JOINED) {
        ++join_count;
    }
}

int CmdInfo(const char* path) {
    if (!Init())
        return 2;
    AZGameInfo info;
    const bool ok = az_get_game_info(path, 1, &info);
    std::printf("ok=%d valid=%d type=%s title=%s title_id=%016llx\n", ok, info.valid,
                info.file_type, info.title, static_cast<unsigned long long>(info.title_id));
    return ok && info.valid ? 0 : 1;
}

int CmdBoot(const char* path, int seconds, bool jit) {
    WriteIni(jit);
    if (!Init())
        return 2;
    std::printf("jit_status=%d\n", static_cast<int>(az_jit_status()));
    std::atomic<int> result{-1};
    std::thread emu([&] { result = static_cast<int>(az_run_game(path)); });

    AZPerfStats best{};
    for (int i = 0; i < seconds * 2; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        AZPerfStats s;
        if (az_get_perf_stats(&s)) {
            std::printf("t=%.1fs system_fps=%.1f speed=%.0f%% frametime=%.2fms\n", (i + 1) / 2.0,
                        s.system_fps, s.emulation_speed * 100.0, s.frametime_ms);
            std::fflush(stdout);
            if (s.system_fps > best.system_fps)
                best = s;
        }
        if (result >= 0)
            break;
    }
    const bool was_running = az_is_running();
    int tw = 0, th = 0, bw = 0, bh = 0;
    const uint64_t frames = az_get_software_frame(0, nullptr, 0, &tw, &th);
    az_get_software_frame(1, nullptr, 0, &bw, &bh);
    AZScreenRect top{}, bottom{};
    const bool rects = az_get_screen_rects(&top, &bottom);
    std::printf("software=%d frames=%llu top=%dx%d bottom=%dx%d rects=%d top@%.0f,%.0f %.0fx%.0f\n",
                az_is_software_renderer(), static_cast<unsigned long long>(frames), tw, th, bw, bh,
                rects, top.x, top.y, top.width, top.height);
    if (const char* shot = std::getenv("AZ_TEST_SHOT")) {
        // Same call as the in-game menu's "截图".
        std::printf("screenshot=%d\n", az_screenshot(shot) ? 1 : 0);
    }
    if (const char* dump = std::getenv("AZ_TEST_DUMP")) {
        // Writes the latest software frames as PPM images (used to check presentation output).
        for (int i = 0; i < 2; ++i) {
            int w = 0, h = 0;
            az_get_software_frame(i, nullptr, 0, &w, &h);
            std::vector<unsigned char> px(static_cast<size_t>(w) * h * 4);
            if (px.empty() || !az_get_software_frame(i, px.data(), static_cast<int>(px.size()), &w, &h))
                continue;
            std::ofstream f(std::string(dump) + (i ? "/bottom.ppm" : "/top.ppm"), std::ios::binary);
            f << "P6\n" << w << " " << h << "\n255\n";
            for (size_t p = 0; p < px.size(); p += 4)
                f.write(reinterpret_cast<const char*>(&px[p]), 3);
        }
    }
    az_stop();
    emu.join();
    char* err = az_last_error_details();
    std::printf("result=%d running_before_stop=%d best_fps=%.1f error='%s'\n", result.load(),
                was_running, best.system_fps, err);
    az_free(err);
    return (result == AZ_RESULT_SUCCESS && was_running && best.system_fps > 30.0) ? 0 : 1;
}

int CmdSaveState(const char* path) {
    WriteIni(true);
    if (!Init())
        return 2;
    std::atomic<int> result{-1};
    std::thread emu([&] { result = static_cast<int>(az_run_game(path)); });
    const auto sleep = [](int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); };
    // Run long enough that a clock which wrongly adds the state's uptime would be visibly off.
    sleep(8000);
    const long long offset_before = az_debug_console_clock_offset_ms();
    az_save_state(1);
    bool saved = false;
    for (int i = 0; i < 50 && !saved; ++i) {
        sleep(100);
        // (az_list_save_states needs a program id, which a bare ELF does not have.)
        std::error_code ec;
        for (const auto& e : std::filesystem::directory_iterator(UserDir() + "/states", ec)) {
            const std::string name = e.path().filename().string();
            saved |= name.size() > 7 && name.ends_with(".01.cst") && e.file_size() > 256;
        }
    }
    std::printf("saved=%d\n", saved);
    bool loads_ok = saved;
    for (int i = 0; i < 3 && loads_ok; ++i) {
        az_load_state(1);
        sleep(1500);
        const uint64_t f1 = az_get_software_frame(0, nullptr, 0, nullptr, nullptr);
        sleep(500);
        const uint64_t f2 = az_get_software_frame(0, nullptr, 0, nullptr, nullptr);
        loads_ok = az_is_running() && f2 > f1;
        std::printf("load %d: running=%d frames %llu -> %llu\n", i + 1, az_is_running(),
                    static_cast<unsigned long long>(f1), static_cast<unsigned long long>(f2));
    }
    // The console clock must still follow the host clock after a load (it used to run ahead by
    // the uptime stored in the state).
    const long long offset_after = az_debug_console_clock_offset_ms();
    // (Emulated time may drift from the host while running, so compare with the drift before the
    // save: the bug added the whole uptime of the state, which is longer than both.)
    const bool clock_ok = std::llabs(offset_after) < std::max(3000LL, std::llabs(offset_before));
    std::printf("clock offset before save %lld ms, after loads %lld ms (%s)\n", offset_before,
                offset_after, clock_ok ? "ok" : "WRONG");
    // Host paths inside a state must survive the user directory moving (iOS gives the app a new
    // container path on reinstall/update): an absolute path from elsewhere is rebased on load...
    const std::string user_dir = FileUtil::GetUserPath(FileUtil::UserPath::UserDir);
    std::string tail = user_dir.substr(0, user_dir.size() - 1);
    tail = tail.substr(tail.rfind('/', tail.rfind('/') - 1));      // "/<parent>/<dir>"
    const std::string foreign = "/old/container" + tail + "/sdmc/Nintendo 3DS/x";
    const std::string rebased = FileUtil::SerializePath(foreign, false);
    const bool rebase_ok = rebased == user_dir + "sdmc/Nintendo 3DS/x";
    std::printf("rebase %s -> %s (%s)\n", foreign.c_str(), rebased.c_str(), rebase_ok ? "ok" : "WRONG");
    // ...and new states store no absolute user-dir paths at all.
    bool relative_ok = false;
    {
        std::ifstream f(UserDir() + "/states/0000000000000000.01.cst", std::ios::binary);
        std::string data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        if (data.size() > 256) {
            Common::Compression::ZstdDecompressStreamBuf buf{std::span<const u8>(
                reinterpret_cast<const u8*>(data.data()) + 256, data.size() - 256)};
            std::istream in{&buf};
            const std::string out((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            relative_ok = !out.empty() && out.find(user_dir) == std::string::npos;
            std::printf("state %zu bytes uncompressed, absolute user-dir paths: %s\n", out.size(),
                        relative_ok ? "none" : "FOUND");
        }
    }
    char* heap = az_debug_heap();
    const bool one_process = std::strstr(heap, "processes=1") != nullptr;
    std::printf("heap: %s\n", heap);
    az_free(heap);
    az_stop();
    emu.join();
    return saved && loads_ok && one_process && rebase_ok && relative_ok && clock_ok ? 0 : 1;
}

int CmdExit(const char* path) {
    WriteIni(true);
    if (!Init())
        return 2;
    std::atomic<int> result{-1};
    std::thread emu([&] { result = static_cast<int>(az_run_game(path)); });
    for (int i = 0; i < 100 && result < 0; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (result < 0) {
        std::printf("program did not exit by itself, stopping\n");
        az_stop();
    }
    emu.join();
    std::printf("result=%d\n", result.load());
    return (result == AZ_RESULT_SHUTDOWN_REQUESTED || result == AZ_RESULT_SUCCESS) ? 0 : 1;
}

int CmdHost(int port, const char* nick, int seconds, const char* lobby, const char* token) {
    if (!Init() || !az_mp_init(MpEvent, nullptr))
        return 2;
    const int r = az_mp_host("iOS test room", "hosted by azios_test", "", static_cast<uint16_t>(port),
                             "", 8, nick, "Test Game", 0x0004000000123400ull, lobby ? lobby : "",
                             token ? token : "");
    std::printf("host_result=%d state=%d hosting=%d\n", r, az_mp_state(), az_mp_is_hosting());
    std::fflush(stdout);
    if (r != AZ_MP_OK)
        return 1;
    for (int i = 0; i < seconds; ++i) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        if (chat_count > 0) {
            az_mp_send_chat("pong from host");
        }
    }
    char* info = az_mp_room_info();
    std::printf("room_info=%s\n", info);
    az_free(info);
    az_mp_shutdown();
    std::printf("host_chats=%d host_joins=%d\n", chat_count.load(), join_count.load());
    return 0;
}

int CmdJoin(const char* addr, int port, const char* nick, const char* msg, int seconds) {
    if (!Init() || !az_mp_init(MpEvent, nullptr))
        return 2;
    const int r = az_mp_join(addr, static_cast<uint16_t>(port), nick, "");
    std::printf("join_result=%d state=%d\n", r, az_mp_state());
    std::fflush(stdout);
    if (r != AZ_MP_OK)
        return 1;
    char* info = az_mp_room_info();
    std::printf("room_info=%s\n", info);
    az_free(info);
    az_mp_send_chat(msg);
    for (int i = 0; i < seconds * 10 && chat_count < 2; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    az_mp_shutdown();
    std::printf("join_chats=%d\n", chat_count.load());
    return 0; // joined; chat delivery is checked on the receiving side
}

/// Creates the same input devices the emulated HID service creates from the settings profile
/// and checks that az_button / az_stick reach them.
int CmdInput() {
    if (!Init())
        return 2;
    auto& profile = Settings::values.current_input_profile;
    auto a = Input::CreateDevice<Input::ButtonDevice>(profile.buttons[Settings::NativeButton::A]);
    auto up = Input::CreateDevice<Input::ButtonDevice>(profile.buttons[Settings::NativeButton::Up]);
    auto pad = Input::CreateDevice<Input::AnalogDevice>(profile.analogs[Settings::NativeAnalog::CirclePad]);
    const bool idle = !a->GetStatus() && !up->GetStatus();
    az_button(AZ_BUTTON_A, true);
    az_stick(AZ_STICK_CIRCLE_PAD, 2.0f, 0.0f); // clamped to the unit circle
    const bool pressed = a->GetStatus() && !up->GetStatus();
    const auto [x, y] = pad->GetStatus();
    az_button(AZ_BUTTON_A, false);
    az_release_all_input();
    const bool released = !a->GetStatus();
    std::printf("idle=%d pressed=%d released=%d stick=(%.2f,%.2f) params=%s\n", idle, pressed,
                released, x, y, profile.buttons[Settings::NativeButton::A].c_str());
    return idle && pressed && released && x > 0.99f && x < 1.01f ? 0 : 1;
}

int CmdLobby(const char* url) {
    if (!Init())
        return 2;
    char* rooms = az_lobby_fetch(url);
    std::printf("rooms=%s\n", rooms ? rooms : "(null)");
    const bool ok = rooms != nullptr;
    az_free(rooms);
    return ok ? 0 : 1;
}

} // namespace

// ----- CIA install / updates / DLC ---------------------------------------------------------

int CmdCiaInfo(const char* path) {
    AZCIAInfo info;
    if (!az_get_cia_info(path, &info)) {
        std::printf("ciainfo failed\n");
        return 1;
    }
    std::printf("title_id=%016llX version=%u kind=%d title=%s\n",
                static_cast<unsigned long long>(info.title_id), info.version,
                static_cast<int>(info.kind), info.title);
    return 0;
}

int CmdInstall(const char* path) {
    WriteIni(false);
    if (!Init())
        return 2;
    const int code = az_install_cia(path, nullptr, nullptr);
    std::printf("install=%d\n", code);
    return code;
}

int CmdTitles() {
    WriteIni(false);
    if (!Init())
        return 2;
    char* t = az_list_installed_titles();
    char* a = az_list_installed_addons();
    std::printf("titles=%s\naddons=%s\n", t, a);
    az_free(t);
    az_free(a);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: see source\n");
        return 2;
    }
    const std::string cmd = argv[1];
    if (cmd == "info" && argc >= 3)
        return CmdInfo(argv[2]);
    if (cmd == "boot" && argc >= 5)
        return CmdBoot(argv[2], std::atoi(argv[3]), std::atoi(argv[4]) != 0);
    if (cmd == "exit" && argc >= 3)
        return CmdExit(argv[2]);
    if (cmd == "host" && argc >= 5)
        return CmdHost(std::atoi(argv[2]), argv[3], std::atoi(argv[4]), argc > 5 ? argv[5] : nullptr,
                       argc > 6 ? argv[6] : nullptr);
    if (cmd == "join" && argc >= 7)
        return CmdJoin(argv[2], std::atoi(argv[3]), argv[4], argv[5], std::atoi(argv[6]));
    if (cmd == "input")
        return CmdInput();
    if (cmd == "ciainfo" && argc >= 3)
        return CmdCiaInfo(argv[2]);
    if (cmd == "install" && argc >= 3)
        return CmdInstall(argv[2]);
    if (cmd == "titles")
        return CmdTitles();
    if (cmd == "savestate" && argc >= 3)
        return CmdSaveState(argv[2]);
    if (cmd == "lobby" && argc >= 3)
        return CmdLobby(argv[2]);
    std::fprintf(stderr, "bad arguments\n");
    return 2;
}
