// AzaharCore.h — C API between the Swift app and the Azahar (3DS) emulation core.
//
// Copyright 2026 3DS_iOS contributors
// Licensed under GPLv2 or any later version (same as Azahar).
//
// Design notes
// - Plain C so Swift can import it through a module map with no Objective-C++ glue.
// - All strings are UTF-8. Strings returned to the caller are heap-allocated and must be
//   released with az_free().
// - az_run_game() blocks for the whole emulation session. Call it from a dedicated thread
//   (8 MB+ stack). Every other function is safe to call from the UI thread.

#ifndef AZAHAR_CORE_H
#define AZAHAR_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------------------------

/// Must be called once, before anything else.
/// user_dir: writable directory for config/, sdmc/, nand/, sysdata/, states/ … (trailing '/' optional)
/// vulkan_library_path: absolute path of the MoltenVK binary to dlopen
///   (e.g. "<bundle>/Frameworks/MoltenVK.framework/MoltenVK"). NULL = let the core search.
bool az_init(const char* user_dir, const char* vulkan_library_path);

/// Re-reads <user_dir>/config/ios-config.ini and applies it (also to a running game where possible).
void az_reload_settings(void);

/// Version string of the bundled Azahar core, e.g. "Azahar 2126.2".
char* az_core_version(void);

void az_free(void* ptr);

// ---------------------------------------------------------------------------------------------
// JIT
// ---------------------------------------------------------------------------------------------

typedef enum {
    AZ_JIT_UNAVAILABLE = 0,   ///< No JIT: the interpreter will be used.
    AZ_JIT_LEGACY = 1,        ///< CS_DEBUGGED set (StikDebug/TrollStore/Xcode on non-TXM devices).
    AZ_JIT_TXM_SCRIPT = 2,    ///< Debugger still attached → iOS 26 "universal" StikDebug script.
    AZ_JIT_DISABLED_BUILD = 3 ///< App Store build: JIT compiled out by policy.
} AZJitStatus;

/// Detects what kind of JIT the process can use right now.
AZJitStatus az_jit_status(void);

// ---------------------------------------------------------------------------------------------
// Game library
// ---------------------------------------------------------------------------------------------

typedef struct {
    bool valid;
    bool encrypted;
    uint64_t title_id;
    char title[256];       ///< Long title in the requested language (falls back to English/Japanese)
    char publisher[128];
    char file_type[32];    ///< "CCI", "CIA", "3DSX", "ELF", "CXI" …
    uint32_t region_mask;  ///< bit0 JPN, bit1 USA, bit2 EUR, bit3 AUS, bit4 CHN, bit5 KOR, bit6 TWN
    uint32_t icon_rgba[48 * 48]; ///< Large SMDH icon as RGBA8888 (0 if no icon)
    bool has_icon;
} AZGameInfo;

/// language: SMDH language index (0 JP, 1 EN, 2 FR, 3 DE, 4 IT, 5 ES, 6 ZH-Hans, 7 KO, 8 NL,
/// 9 PT, 10 RU, 11 ZH-Hant). Returns false if the file cannot be parsed at all.
bool az_get_game_info(const char* path, int language, AZGameInfo* out);

typedef void (*AZProgressCallback)(uint64_t done, uint64_t total, void* ctx);

/// Installs a .cia into the emulated SD/NAND. Returns 0 on success, otherwise
/// 1 = error, 2 = encrypted, 3 = invalid, 4 = file not found, 5 = aborted.
int az_install_cia(const char* path, AZProgressCallback cb, void* ctx);

/// JSON array of installed, bootable titles (applications and demos):
/// [{"path":"…","title_id":123}]
char* az_list_installed_titles(void);

typedef enum {
    AZ_TITLE_APPLICATION = 0, ///< 00040000 (and demos, 00040002)
    AZ_TITLE_UPDATE = 1,      ///< 0004000E: patch for the application with the same low 32 bits
    AZ_TITLE_DLC = 2,         ///< 0004008C: add-on content for that application
    AZ_TITLE_OTHER = 3,       ///< system titles, applets, …
} AZTitleKind;

typedef struct {
    uint64_t title_id;
    uint16_t version;   ///< TMD version: major = v >> 10, minor = (v >> 4) & 0x3F, micro = v & 0xF
    AZTitleKind kind;
    char title[256];    ///< short title from the CIA's SMDH (UTF-8), empty if the CIA has none
} AZCIAInfo;

/// Reads a .cia's title ID, version and kind without installing it.
bool az_get_cia_info(const char* path, AZCIAInfo* out);

/// Kind of a title ID (see AZTitleKind).
AZTitleKind az_title_kind(uint64_t title_id);

/// JSON array of installed updates and DLC on the emulated SD card:
/// [{"title_id":123,"kind":"update","version":1040}]
char* az_list_installed_addons(void);

// ---------------------------------------------------------------------------------------------
// Emulation session
// ---------------------------------------------------------------------------------------------

typedef enum {
    AZ_RESULT_SUCCESS = 0,
    AZ_RESULT_SHUTDOWN_REQUESTED = 1,
    AZ_RESULT_ERROR_GET_LOADER = 2,
    AZ_RESULT_ERROR_SYSTEM_MODE = 3,
    AZ_RESULT_ERROR_LOADER = 4,
    AZ_RESULT_ERROR_ENCRYPTED = 5,
    AZ_RESULT_ERROR_INVALID_FORMAT = 6,
    AZ_RESULT_ERROR_SYSTEM_FILES = 7,
    AZ_RESULT_ERROR_VIDEO_CORE = 8,
    AZ_RESULT_ERROR_OTHER = 9,
    AZ_RESULT_ERROR_NO_SURFACE = 10,
    AZ_RESULT_ERROR_GBA_TITLE = 11,
} AZResult;

/// Hands the rendering surface to the core. On Apple platforms `surface` is a CAMetalLayer*
/// (pass an unretained pointer; the caller keeps the layer alive). width/height in pixels.
/// Call again whenever the drawable size changes (rotation, split view …). NULL detaches.
void az_set_surface(void* surface, int width_px, int height_px, bool is_portrait);

/// Shader-cache loading progress while a game boots (stage: 0 prepare, 1 preload, 2 decompile,
/// 3 build, 4 complete). Called on the emulation thread.
typedef void (*AZLoadingCallback)(int stage, uint64_t value, uint64_t total, void* ctx);
void az_set_loading_callback(AZLoadingCallback cb, void* ctx);

/// Runs the game at `path` until az_stop() is called or the game exits. Blocking.
AZResult az_run_game(const char* path);

void az_pause(bool paused);
bool az_is_paused(void);
void az_stop(void);
bool az_is_running(void);
uint64_t az_running_title_id(void);

/// Optional extra text for the last error (e.g. missing system file name).
char* az_last_error_details(void);
/// A save/load state request that failed while the game kept running, or NULL. Each failure is
/// returned once ("version:" prefix = state from another build). Free with az_free().
char* az_take_state_error(void);

typedef struct {
    double system_fps;
    double game_fps;
    double emulation_speed; ///< 1.0 == 100 %
    double frametime_ms;
} AZPerfStats;
bool az_get_perf_stats(AZPerfStats* out);

/// A visible stall (> 100 ms). kind: 0 = no emulated frame (emulation stopped),
/// 1 = the game showed no newly drawn picture (it swapped without drawing),
/// 2 = nothing reached the display (presentation stalled).
typedef struct {
    double at_s;   ///< seconds since the session started
    double gap_ms; ///< length of the stall
    int kind;
} AZHitch;
/// Copies stalls recorded after *cursor (at most max; the newest 256 are kept) and advances
/// *cursor. Start with *cursor = 0. Pauses are not counted.
int az_get_hitches(uint64_t* cursor, AZHitch* out, int max);

/// Temporary speed override (fast-forward). 0 disables the override.
void az_set_speed_override(double percent);

// Save states (slot 0 is reserved for the auto-save, 1…10 are user slots).
void az_save_state(int slot);
void az_load_state(int slot);
/// JSON array: [{"slot":1,"time":1700000000}]
char* az_list_save_states(void);

/// Writes a PNG of the current top screen to `path`.
bool az_screenshot(const char* path);

/// Debug: the live malloc blocks of at least 512 KiB, as "size×count" sorted by total size, plus
/// totals. Used to find what grows after save states. Release with az_free().
char* az_debug_heap(void);
/// Debug: from now on remember the call stack of every malloc of at least `min_bytes`;
/// az_debug_heap() then also lists where the still-live ones came from.
void az_debug_track_big_allocs(size_t min_bytes);
/// Debug: emulated console clock minus host local time, in ms (INT64_MIN when not running).
int64_t az_debug_console_clock_offset_ms(void);
/// Debug: samples the emulation thread's call stack `hz` times per second for `seconds`
/// (suspend, read registers, walk frame pointers, resume) and writes one line per sample to
/// `path`: image-relative return addresses, leaf first. Returns the sample count, or -1.
int az_debug_profile(const char* path, int seconds, int hz);
/// Debug: in a build instrumented with -fprofile-instr-generate, writes the profile counters to
/// `path` (for PGO). Returns 0 on success, -1 when the build is not instrumented.
int az_debug_write_pgo_profile(const char* path);
/// Debug: how the interpreter runs VFP arithmetic: 0 in software, 1 on the host FPU decoding
/// each time, 2 on the host FPU decoded at translation (default). `set` 0–2 changes it, -1 only
/// reads it. Returns -1 where the host FPU path does not exist.
int az_debug_vfp_native(int set);
/// Debug: whether the interpreter runs its tail-call copy (1) or the original loop (0); `set` 0
/// or 1 changes it (from the next interpreter run), -1 only reads it. -1 where not built.
int az_debug_dyncom_tailcall(int set);
/// Debug: whether direct branches link straight to their target block (1, default) or always go
/// through the dispatch lookup (0); `set` 0 or 1 changes it at once, -1 only reads it.
int az_debug_dyncom_link(int set);
/// Debug: whether common ARM instruction forms get specialised handlers (1, default) or all use
/// the generic ones (0); changing it makes every core retranslate. -1 only reads it.
int az_debug_dyncom_special(int set);

// ---- Software renderer presentation ------------------------------------------------------------
// Used in the iOS Simulator (its Metal driver cannot run MoltenVK's texel buffers) and as the
// "compatibility" renderer on devices. The app draws the frames itself.

typedef struct {
    float x, y, width, height; ///< in surface pixels (the space of az_set_surface)
    bool enabled;
} AZScreenRect;

/// True while a game runs with the software renderer.
bool az_is_software_renderer(void);

/// Copies the latest frame of `screen` (0 = top, 1 = bottom) as tightly packed RGBA8888.
/// Pass rgba = NULL to query the size. Returns a frame counter that increases with every new
/// frame (0 = no frame yet); unchanged counter means nothing new to draw.
uint64_t az_get_software_frame(int screen, uint8_t* rgba, int capacity, int* width, int* height);

/// Where the core places the two screens inside the surface (follows layout/swap settings).
bool az_get_screen_rects(AZScreenRect* top, AZScreenRect* bottom);

void az_swap_screens(bool swapped);
/// Layout: 0 default (stacked), 1 single, 2 large+small, 3 side by side, 4 hybrid.
void az_set_layout(int layout, bool is_portrait);

// ---------------------------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------------------------

typedef enum {
    AZ_BUTTON_A = 0,
    AZ_BUTTON_B,
    AZ_BUTTON_X,
    AZ_BUTTON_Y,
    AZ_BUTTON_UP,
    AZ_BUTTON_DOWN,
    AZ_BUTTON_LEFT,
    AZ_BUTTON_RIGHT,
    AZ_BUTTON_L,
    AZ_BUTTON_R,
    AZ_BUTTON_START,
    AZ_BUTTON_SELECT,
    AZ_BUTTON_DEBUG,
    AZ_BUTTON_GPIO14,
    AZ_BUTTON_ZL,
    AZ_BUTTON_ZR,
    AZ_BUTTON_HOME,
    AZ_BUTTON_COUNT
} AZButton;

typedef enum {
    AZ_STICK_CIRCLE_PAD = 0,
    AZ_STICK_C_STICK = 1,
} AZStick;

void az_button(AZButton button, bool pressed);
/// x/y in [-1, 1], +y is up.
void az_stick(AZStick stick, float x, float y);
void az_release_all_input(void);

/// Touch in surface pixel coordinates (same space as az_set_surface width/height).
/// Returns true if the point is on the emulated touch screen.
bool az_touch_begin(float x, float y);
void az_touch_move(float x, float y);
void az_touch_end(void);

/// Raw CoreMotion device-frame values: acceleration (gravity + user) in g, rotation rate in rad/s.
/// The core converts them to the 3DS frame using the orientation set below.
void az_motion(float ax, float ay, float az, float gx, float gy, float gz);
/// Interface rotation in 90° counter-clockwise steps from portrait (0 portrait, 1 landscape-left
/// i.e. home indicator on the right, 2 upside down, 3 landscape-right).
void az_set_motion_orientation(int rotation);

// ---------------------------------------------------------------------------------------------
// Applets: software keyboard. The callback runs on the emulation thread and may block
// until the user finished typing. Return a malloc'd UTF-8 string (freed by the core) and set
// *button to the pressed button index (0 = left/cancel, 1 = middle, 2 = right/ok).
// ---------------------------------------------------------------------------------------------

typedef char* (*AZKeyboardCallback)(const char* hint, int max_length, bool multiline,
                                    int button_count, int* out_button, void* ctx);
void az_set_keyboard_callback(AZKeyboardCallback cb, void* ctx);

// ---------------------------------------------------------------------------------------------
// System
// ---------------------------------------------------------------------------------------------

/// The emulated console nickname (also the default multiplayer nickname).
char* az_get_console_username(void);
void az_set_console_username(const char* name);

// ---------------------------------------------------------------------------------------------
// Multiplayer (Azahar/Citra room protocol — emulates 3DS local wireless over the internet/LAN)
// ---------------------------------------------------------------------------------------------

typedef enum {
    AZ_MP_STATE_IDLE = 0,
    AZ_MP_STATE_JOINING = 1,
    AZ_MP_STATE_JOINED = 2,
    AZ_MP_STATE_MODERATOR = 3,
} AZMultiplayerState;

typedef enum {
    AZ_MP_EVENT_STATE_CHANGED = 0,   ///< message = new state as decimal
    AZ_MP_EVENT_ERROR = 1,           ///< message = error code name (see AzaharCore.h docs)
    AZ_MP_EVENT_CHAT = 2,            ///< message = JSON {"nickname":…, "message":…}
    AZ_MP_EVENT_MEMBER_JOINED = 3,   ///< message = nickname
    AZ_MP_EVENT_MEMBER_LEFT = 4,
    AZ_MP_EVENT_MEMBER_KICKED = 5,
    AZ_MP_EVENT_MEMBER_BANNED = 6,
    AZ_MP_EVENT_ADDRESS_UNBANNED = 7,
    AZ_MP_EVENT_ROOM_INFO_CHANGED = 8,
    AZ_MP_EVENT_ANNOUNCE_ERROR = 9,  ///< message = lobby error text
} AZMultiplayerEvent;

/// Called on a network thread. Copy `message` if you need it later.
typedef void (*AZMultiplayerCallback)(AZMultiplayerEvent event, const char* message, void* ctx);

bool az_mp_init(AZMultiplayerCallback cb, void* ctx);
void az_mp_shutdown(void);

/// Hosts a room on this device and joins it.
/// bind_address: "" = all interfaces. lobby_url: "" = private room (not announced).
/// lobby_token: token for the lobby server (any non-empty string on an open lobby).
/// Returns 0 on success, otherwise an AZ_MP_ERR_* code.
int az_mp_host(const char* room_name, const char* description, const char* bind_address,
               uint16_t port, const char* password, int max_players, const char* nickname,
               const char* preferred_game, uint64_t preferred_game_id, const char* lobby_url,
               const char* lobby_token);

/// Joins a room (blocking for up to ~5 s). Returns 0 on success, otherwise AZ_MP_ERR_*.
int az_mp_join(const char* address, uint16_t port, const char* nickname, const char* password);

void az_mp_leave(void);
AZMultiplayerState az_mp_state(void);
bool az_mp_is_hosting(void);
void az_mp_send_chat(const char* message);
void az_mp_kick(const char* nickname);
void az_mp_ban(const char* nickname);

/// JSON: {"name":…, "description":…, "max_players":n, "port":n, "preferred_game":…,
///        "members":[{"nickname":…, "game":…, "game_id":n, "mac":"…"}]}
char* az_mp_room_info(void);

/// Fetches the public room list from an Azahar-compatible lobby server (blocking HTTP).
/// Returns a JSON array of rooms or NULL on network failure.
char* az_lobby_fetch(const char* lobby_url);

enum {
    AZ_MP_OK = 0,
    AZ_MP_ERR_NETWORK = 1,
    AZ_MP_ERR_ALREADY_IN_ROOM = 2,
    AZ_MP_ERR_CREATE_ROOM = 3,
    AZ_MP_ERR_COULD_NOT_CONNECT = 4,
    AZ_MP_ERR_WRONG_PASSWORD = 5,
    AZ_MP_ERR_NAME_COLLISION = 6,
    AZ_MP_ERR_ROOM_FULL = 7,
    AZ_MP_ERR_WRONG_VERSION = 8,
    AZ_MP_ERR_BANNED = 9,
    AZ_MP_ERR_INVALID_NAME = 10,
    AZ_MP_ERR_CONSOLE_ID_COLLISION = 11,
    AZ_MP_ERR_MAC_COLLISION = 12,
    AZ_MP_ERR_TIMEOUT = 13,
};

/// Default room port used by Azahar/Citra (24872).
uint16_t az_mp_default_port(void);

#ifdef __cplusplus
}
#endif

#endif // AZAHAR_CORE_H
