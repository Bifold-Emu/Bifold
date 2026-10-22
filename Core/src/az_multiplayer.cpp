// Multiplayer: Azahar/Citra room protocol (emulated 3DS local wireless over ENet/UDP).
// Fully compatible with Azahar desktop/Android rooms and the dedicated azahar-room server.
// Licensed under GPLv2 or any later version.

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <optional>
#include <thread>

#include "az_internal.h"
#include "common/logging/log.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/hle/service/cfg/cfg.h"
#include "network/announce_multiplayer_session.h"
#include "network/network.h"
#include "network/room.h"
#include "network/room_member.h"
#ifdef ENABLE_WEB_SERVICE
#include "web_service/announce_room_json.h"
#endif

namespace AzIOS::Multiplayer {

namespace {

std::mutex mp_mutex;
bool network_ready = false;
AZMultiplayerCallback event_cb = nullptr;
void* event_ctx = nullptr;

std::shared_ptr<Network::AnnounceMultiplayerSession> announce_session;
Network::AnnounceMultiplayerSession::CallbackHandle announce_error_handle;

Network::RoomMember::CallbackHandle<Network::RoomMember::State> state_handle;
Network::RoomMember::CallbackHandle<Network::RoomMember::Error> error_handle;
Network::RoomMember::CallbackHandle<Network::ChatEntry> chat_handle;
Network::RoomMember::CallbackHandle<Network::StatusMessageEntry> status_handle;
Network::RoomMember::CallbackHandle<Network::RoomInformation> info_handle;

std::mutex last_error_mutex;
std::optional<Network::RoomMember::Error> last_error;

Network::GameInfo current_game;

void Emit(AZMultiplayerEvent ev, const std::string& msg) {
    AZMultiplayerCallback cb;
    void* ctx;
    {
        std::scoped_lock lock{mp_mutex};
        cb = event_cb;
        ctx = event_ctx;
    }
    if (cb) {
        cb(ev, msg.c_str(), ctx);
    }
}

std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const unsigned char c : in) {
        switch (c) {
        case '"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out;
}

std::string Quote(const std::string& s) {
    return "\"" + JsonEscape(s) + "\"";
}

const char* ErrorName(Network::RoomMember::Error e) {
    using E = Network::RoomMember::Error;
    switch (e) {
    case E::LostConnection:
        return "LostConnection";
    case E::HostKicked:
        return "HostKicked";
    case E::UnknownError:
        return "UnknownError";
    case E::NameCollision:
        return "NameCollision";
    case E::MacCollision:
        return "MacCollision";
    case E::ConsoleIdCollision:
        return "ConsoleIdCollision";
    case E::WrongVersion:
        return "WrongVersion";
    case E::WrongPassword:
        return "WrongPassword";
    case E::CouldNotConnect:
        return "CouldNotConnect";
    case E::RoomIsFull:
        return "RoomIsFull";
    case E::HostBanned:
        return "HostBanned";
    case E::PermissionDenied:
        return "PermissionDenied";
    case E::NoSuchUser:
        return "NoSuchUser";
    }
    return "UnknownError";
}

int ErrorCode(Network::RoomMember::Error e) {
    using E = Network::RoomMember::Error;
    switch (e) {
    case E::NameCollision:
        return AZ_MP_ERR_NAME_COLLISION;
    case E::MacCollision:
        return AZ_MP_ERR_MAC_COLLISION;
    case E::ConsoleIdCollision:
        return AZ_MP_ERR_CONSOLE_ID_COLLISION;
    case E::WrongVersion:
        return AZ_MP_ERR_WRONG_VERSION;
    case E::WrongPassword:
        return AZ_MP_ERR_WRONG_PASSWORD;
    case E::RoomIsFull:
        return AZ_MP_ERR_ROOM_FULL;
    case E::HostBanned:
        return AZ_MP_ERR_BANNED;
    case E::CouldNotConnect:
    case E::LostConnection:
        return AZ_MP_ERR_COULD_NOT_CONNECT;
    default:
        return AZ_MP_ERR_NETWORK;
    }
}

bool IsJoined(Network::RoomMember::State s) {
    return s == Network::RoomMember::State::Joined || s == Network::RoomMember::State::Moderator;
}

std::string ConsoleIdHash() {
    return Service::CFG::GetConsoleIdHash(Core::System::GetInstance());
}

Network::MacAddress ConsoleMac() {
    // Same as the desktop client: a stable per-console MAC so games can recognise players.
    return Service::CFG::GetConsoleMacAddress(Core::System::GetInstance());
}

void BindCallbacks(const std::shared_ptr<Network::RoomMember>& member) {
    state_handle = member->BindOnStateChanged([](const Network::RoomMember::State& s) {
        AZMultiplayerState mapped = AZ_MP_STATE_IDLE;
        switch (s) {
        case Network::RoomMember::State::Joining:
            mapped = AZ_MP_STATE_JOINING;
            break;
        case Network::RoomMember::State::Joined:
            mapped = AZ_MP_STATE_JOINED;
            break;
        case Network::RoomMember::State::Moderator:
            mapped = AZ_MP_STATE_MODERATOR;
            break;
        default:
            break;
        }
        Emit(AZ_MP_EVENT_STATE_CHANGED, std::to_string(static_cast<int>(mapped)));
        if (IsJoined(s)) {
            if (auto m = Network::GetRoomMember().lock(); m && !current_game.name.empty()) {
                m->SendGameInfo(current_game);
            }
        }
    });
    error_handle = member->BindOnError([](const Network::RoomMember::Error& e) {
        {
            std::scoped_lock lock{last_error_mutex};
            last_error = e;
        }
        Emit(AZ_MP_EVENT_ERROR, ErrorName(e));
    });
    chat_handle = member->BindOnChatMessageRecieved([](const Network::ChatEntry& chat) {
        Emit(AZ_MP_EVENT_CHAT, "{\"nickname\":" + Quote(chat.nickname) +
                                   ",\"username\":" + Quote(chat.username) +
                                   ",\"message\":" + Quote(chat.message) + "}");
    });
    status_handle =
        member->BindOnStatusMessageReceived([](const Network::StatusMessageEntry& status) {
            AZMultiplayerEvent ev = AZ_MP_EVENT_MEMBER_JOINED;
            switch (status.type) {
            case Network::IdMemberJoin:
                ev = AZ_MP_EVENT_MEMBER_JOINED;
                break;
            case Network::IdMemberLeave:
                ev = AZ_MP_EVENT_MEMBER_LEFT;
                break;
            case Network::IdMemberKicked:
                ev = AZ_MP_EVENT_MEMBER_KICKED;
                break;
            case Network::IdMemberBanned:
                ev = AZ_MP_EVENT_MEMBER_BANNED;
                break;
            case Network::IdAddressUnbanned:
                ev = AZ_MP_EVENT_ADDRESS_UNBANNED;
                break;
            }
            Emit(ev, status.nickname);
        });
    info_handle = member->BindOnRoomInformationChanged(
        [](const Network::RoomInformation& info) { Emit(AZ_MP_EVENT_ROOM_INFO_CHANGED, info.name); });
}

void UnbindCallbacks() {
    if (auto member = Network::GetRoomMember().lock()) {
        if (state_handle)
            member->Unbind(state_handle);
        if (error_handle)
            member->Unbind(error_handle);
        if (chat_handle)
            member->Unbind(chat_handle);
        if (status_handle)
            member->Unbind(status_handle);
        if (info_handle)
            member->Unbind(info_handle);
    }
    state_handle = {};
    error_handle = {};
    chat_handle = {};
    status_handle = {};
    info_handle = {};
}

/// Waits until the member is joined or failed. Returns AZ_MP_OK or an error code.
int WaitForJoin(const std::shared_ptr<Network::RoomMember>& member, std::chrono::milliseconds max) {
    const auto deadline = std::chrono::steady_clock::now() + max;
    while (std::chrono::steady_clock::now() < deadline) {
        const auto state = member->GetState();
        if (IsJoined(state)) {
            return AZ_MP_OK;
        }
        {
            std::scoped_lock lock{last_error_mutex};
            if (last_error) {
                return ErrorCode(*last_error);
            }
        }
        if (state == Network::RoomMember::State::Idle && !member->IsConnected()) {
            // Join() failed synchronously or the connection was refused.
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return AZ_MP_ERR_TIMEOUT;
}

void StopAnnounce() {
    if (announce_session) {
        if (announce_error_handle) {
            announce_session->UnbindErrorCallback(announce_error_handle);
            announce_error_handle = {};
        }
        announce_session->Stop();
        announce_session.reset();
    }
}

} // namespace

void OnGameStarted(const std::string& name, unsigned long long title_id) {
    current_game.name = name;
    current_game.id = title_id;
    if (auto member = Network::GetRoomMember().lock(); member && IsJoined(member->GetState())) {
        member->SendGameInfo(current_game);
    }
}

void OnGameStopped() {
    current_game = {};
    if (auto member = Network::GetRoomMember().lock(); member && IsJoined(member->GetState())) {
        member->SendGameInfo(current_game);
    }
}

} // namespace AzIOS::Multiplayer

using namespace AzIOS::Multiplayer;

extern "C" {

bool az_mp_init(AZMultiplayerCallback cb, void* ctx) {
    {
        std::scoped_lock lock{mp_mutex};
        event_cb = cb;
        event_ctx = ctx;
        if (network_ready) {
            return true;
        }
    }
    if (!Network::Init()) {
        return false;
    }
    if (auto member = Network::GetRoomMember().lock()) {
        BindCallbacks(member);
    }
    std::scoped_lock lock{mp_mutex};
    network_ready = true;
    return true;
}

void az_mp_shutdown(void) {
    az_mp_leave();
    UnbindCallbacks();
    {
        std::scoped_lock lock{mp_mutex};
        if (!network_ready) {
            return;
        }
        network_ready = false;
    }
    Network::Shutdown();
}

int az_mp_host(const char* room_name, const char* description, const char* bind_address,
               uint16_t port, const char* password, int max_players, const char* nickname,
               const char* preferred_game, uint64_t preferred_game_id, const char* lobby_url,
               const char* lobby_token) {
    if (!network_ready && !az_mp_init(event_cb, event_ctx)) {
        return AZ_MP_ERR_NETWORK;
    }
    auto member = Network::GetRoomMember().lock();
    auto room = Network::GetRoom().lock();
    if (!member || !room) {
        return AZ_MP_ERR_NETWORK;
    }
    if (member->GetState() == Network::RoomMember::State::Joining || member->IsConnected()) {
        return AZ_MP_ERR_ALREADY_IN_ROOM;
    }
    const std::string name = room_name ? room_name : "";
    const std::string nick = nickname ? nickname : "";
    if (name.size() < 3 || name.size() > 20 || nick.size() < 4 || nick.size() > 20) {
        // Same limits as the desktop client (nickname 4-20, room name 3-20 characters).
        return AZ_MP_ERR_INVALID_NAME;
    }

    const std::string url = lobby_url ? lobby_url : "";
    const std::string token = lobby_token ? lobby_token : "";
    const bool is_public = !url.empty() && !token.empty();

    if (!room->Create(name, description ? description : "", bind_address ? bind_address : "",
                      port ? port : Network::DefaultRoomPort, password ? password : "",
                      static_cast<u32>(std::clamp(max_players, 2, 16)), nick,
                      preferred_game ? preferred_game : "", preferred_game_id,
                      std::make_unique<Network::VerifyUser::NullBackend>(), {})) {
        return AZ_MP_ERR_CREATE_ROOM;
    }

    if (is_public) {
#ifdef ENABLE_WEB_SERVICE
        Settings::values.web_api_url = url;
        Settings::values.network_token = token;
        announce_session = std::make_shared<Network::AnnounceMultiplayerSession>(nick);
        announce_error_handle = announce_session->BindErrorCallback(
            [](const Common::WebResult& result) {
                Emit(AZ_MP_EVENT_ANNOUNCE_ERROR,
                     result.result_string.empty() ? std::string("announce failed")
                                                  : result.result_string);
            });
        announce_session->Start();
#endif
    }

    {
        std::scoped_lock lock{last_error_mutex};
        last_error.reset();
    }
    member->Join(nick, ConsoleIdHash(), "127.0.0.1", port ? port : Network::DefaultRoomPort, 0,
                 ConsoleMac(), password ? password : "");

    const int result = WaitForJoin(member, std::chrono::seconds(3));
    if (result != AZ_MP_OK) {
        StopAnnounce();
        room->Destroy();
    }
    return result;
}

int az_mp_join(const char* address, uint16_t port, const char* nickname, const char* password) {
    if (!network_ready && !az_mp_init(event_cb, event_ctx)) {
        return AZ_MP_ERR_NETWORK;
    }
    auto member = Network::GetRoomMember().lock();
    if (!member) {
        return AZ_MP_ERR_NETWORK;
    }
    if (member->GetState() == Network::RoomMember::State::Joining || member->IsConnected()) {
        return AZ_MP_ERR_ALREADY_IN_ROOM;
    }
    const std::string nick = nickname ? nickname : "";
    if (nick.size() < 4 || nick.size() > 20 || !address || !*address) {
        return AZ_MP_ERR_INVALID_NAME;
    }
    {
        std::scoped_lock lock{last_error_mutex};
        last_error.reset();
    }
    member->Join(nick, ConsoleIdHash(), address, port ? port : Network::DefaultRoomPort, 0,
                 ConsoleMac(), password ? password : "");
    const int result = WaitForJoin(member, std::chrono::seconds(6));
    if (result != AZ_MP_OK && member->IsConnected()) {
        member->Leave();
    }
    return result;
}

void az_mp_leave(void) {
    if (!network_ready) {
        return;
    }
    if (auto member = Network::GetRoomMember().lock()) {
        if (member->IsConnected()) {
            member->Leave();
        }
    }
    StopAnnounce();
    if (auto room = Network::GetRoom().lock()) {
        if (room->GetState() == Network::Room::State::Open) {
            room->Destroy();
        }
    }
}

AZMultiplayerState az_mp_state(void) {
    if (!network_ready) {
        return AZ_MP_STATE_IDLE;
    }
    auto member = Network::GetRoomMember().lock();
    if (!member) {
        return AZ_MP_STATE_IDLE;
    }
    switch (member->GetState()) {
    case Network::RoomMember::State::Joining:
        return AZ_MP_STATE_JOINING;
    case Network::RoomMember::State::Joined:
        return AZ_MP_STATE_JOINED;
    case Network::RoomMember::State::Moderator:
        return AZ_MP_STATE_MODERATOR;
    default:
        return AZ_MP_STATE_IDLE;
    }
}

bool az_mp_is_hosting(void) {
    if (!network_ready) {
        return false;
    }
    auto room = Network::GetRoom().lock();
    return room && room->GetState() == Network::Room::State::Open;
}

void az_mp_send_chat(const char* message) {
    if (!network_ready || !message) {
        return;
    }
    if (auto member = Network::GetRoomMember().lock(); member && IsJoined(member->GetState())) {
        std::string msg = message;
        if (msg.size() > Network::MaxMessageSize) {
            msg.resize(Network::MaxMessageSize);
        }
        member->SendChatMessage(msg);
    }
}

void az_mp_kick(const char* nickname) {
    if (auto member = Network::GetRoomMember().lock(); member && nickname) {
        member->SendModerationRequest(Network::IdModKick, nickname);
    }
}

void az_mp_ban(const char* nickname) {
    if (auto member = Network::GetRoomMember().lock(); member && nickname) {
        member->SendModerationRequest(Network::IdModBan, nickname);
    }
}

char* az_mp_room_info(void) {
    auto member = network_ready ? Network::GetRoomMember().lock() : nullptr;
    if (!member || !IsJoined(member->GetState())) {
        return AzIOS::DupString("{}");
    }
    const auto info = member->GetRoomInformation();
    std::string json = "{\"name\":" + Quote(info.name) + ",\"description\":" +
                       Quote(info.description) +
                       ",\"max_players\":" + std::to_string(info.member_slots) +
                       ",\"port\":" + std::to_string(info.port) +
                       ",\"preferred_game\":" + Quote(info.preferred_game) +
                       ",\"preferred_game_id\":" + std::to_string(info.preferred_game_id) +
                       ",\"host\":" + Quote(info.host_username) + ",\"members\":[";
    bool first = true;
    for (const auto& m : member->GetMemberInformation()) {
        char mac[18];
        std::snprintf(mac, sizeof(mac), "%02X:%02X:%02X:%02X:%02X:%02X", m.mac_address[0],
                      m.mac_address[1], m.mac_address[2], m.mac_address[3], m.mac_address[4],
                      m.mac_address[5]);
        json += (first ? "" : ",");
        json += "{\"nickname\":" + Quote(m.nickname) + ",\"username\":" + Quote(m.username) +
                ",\"game\":" + Quote(m.game_info.name) +
                ",\"game_id\":" + std::to_string(m.game_info.id) + ",\"mac\":\"" + mac + "\"}";
        first = false;
    }
    json += "]}";
    return AzIOS::DupString(json);
}

char* az_lobby_fetch(const char* lobby_url) {
#ifdef ENABLE_WEB_SERVICE
    if (!lobby_url || !*lobby_url) {
        return nullptr;
    }
    WebService::RoomJson backend(lobby_url, "", "");
    AnnounceMultiplayerRoom::RoomList rooms;
    try {
        rooms = backend.GetRoomList();
    } catch (const std::exception& e) {
        LOG_ERROR(Network, "Lobby response could not be parsed: {}", e.what());
        return nullptr;
    }
    std::string json = "[";
    bool first_room = true;
    for (const auto& r : rooms) {
        json += first_room ? "" : ",";
        first_room = false;
        json += "{\"id\":" + Quote(r.id) + ",\"name\":" + Quote(r.name) +
                ",\"description\":" + Quote(r.description) + ",\"owner\":" + Quote(r.owner) +
                ",\"address\":" + Quote(r.ip) + ",\"port\":" + std::to_string(r.port) +
                ",\"max_players\":" + std::to_string(r.max_player) +
                ",\"net_version\":" + std::to_string(r.net_version) +
                ",\"has_password\":" + (r.has_password ? "true" : "false") +
                ",\"preferred_game\":" + Quote(r.preferred_game) +
                ",\"preferred_game_id\":" + std::to_string(r.preferred_game_id) +
                ",\"compatible\":" + (r.net_version == Network::network_version ? "true" : "false") +
                ",\"members\":[";
        bool first_member = true;
        for (const auto& m : r.members) {
            json += first_member ? "" : ",";
            first_member = false;
            json += "{\"nickname\":" + Quote(m.nickname) + ",\"game\":" + Quote(m.game_name) +
                    ",\"game_id\":" + std::to_string(m.game_id) + "}";
        }
        json += "]}";
    }
    json += "]";
    return AzIOS::DupString(json);
#else
    (void)lobby_url;
    return nullptr;
#endif
}

uint16_t az_mp_default_port(void) {
    return Network::DefaultRoomPort;
}

} // extern "C"
