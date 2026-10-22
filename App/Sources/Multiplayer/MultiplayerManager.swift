import AzaharCore
import Foundation

/// Multiplayer state for the UI. Rooms use Azahar's protocol (emulated 3DS local wireless),
/// so iOS players can meet Azahar desktop/Android players and dedicated `azahar-room` servers.
@MainActor
final class MultiplayerManager: ObservableObject {
    static let shared = MultiplayerManager()

    struct Member: Decodable, Identifiable, Hashable {
        let nickname: String
        let username: String?
        let game: String
        let game_id: UInt64
        let mac: String
        var id: String { nickname + mac }
    }

    struct RoomInfo: Decodable {
        var name: String?
        var description: String?
        var max_players: Int?
        var port: Int?
        var preferred_game: String?
        var host: String?
        var members: [Member]?
    }

    struct LobbyRoom: Decodable, Identifiable, Hashable {
        let name: String
        let description: String
        let owner: String
        let address: String
        let port: UInt16
        let max_players: Int
        let has_password: Bool
        let preferred_game: String
        let compatible: Bool
        let members: [LobbyMember]
        var id: String { "\(address):\(port)" }
        struct LobbyMember: Decodable, Hashable { let nickname: String; let game: String }
    }

    struct ChatLine: Identifiable, Hashable {
        let id = UUID()
        let nickname: String
        let text: String
        let isSystem: Bool
    }

    @Published private(set) var state: AZMultiplayerState = AZ_MP_STATE_IDLE
    @Published private(set) var isHosting = false
    @Published private(set) var roomName = ""
    @Published private(set) var members: [Member] = []
    @Published private(set) var chat: [ChatLine] = []
    @Published private(set) var lobbyRooms: [LobbyRoom] = []
    @Published private(set) var lobbyError: String?
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    let lan = LANDiscovery()
    private var initialized = false

    private init() {}

    /// Must run before a game boots: the emulated 3DS wireless service (NWM_UDS) only works if
    /// the network layer exists when the game starts.
    func ensureInit() {
        guard !initialized else { return }
        initialized = az_mp_init(multiplayerCallback, nil)
    }

    var isConnected: Bool { state == AZ_MP_STATE_JOINED || state == AZ_MP_STATE_MODERATOR }
    var isModerator: Bool { state == AZ_MP_STATE_MODERATOR }

    // MARK: Actions

    func host(name: String, port: UInt16, password: String, maxPlayers: Int, isPublic: Bool,
              preferredGame: Game?) {
        ensureInit()
        let s = AppSettings.shared
        let nick = s.nickname, lobby = isPublic ? s.lobbyURL : "", token = isPublic ? s.lobbyToken : ""
        let gameName = preferredGame?.title ?? "", gameID = preferredGame?.titleID ?? 0
        isBusy = true
        Task.detached {
            let r = az_mp_host(name, "", "", port, password, Int32(maxPlayers), nick, gameName, gameID, lobby, token)
            await MainActor.run {
                self.isBusy = false
                if Int(r) == Int(AZ_MP_OK) {
                    self.isHosting = true
                    self.chat.removeAll()
                    self.refreshRoomInfo()
                    if AppSettings.shared.lanDiscovery {
                        self.lan.advertise(roomName: name, port: port, hasPassword: !password.isEmpty,
                                           maxPlayers: maxPlayers, game: gameName)
                    }
                } else {
                    self.lastError = Self.describe(Int(r))
                }
            }
        }
    }

    func join(address: String, port: UInt16, password: String) {
        ensureInit()
        let nick = AppSettings.shared.nickname
        isBusy = true
        Task.detached {
            let r = az_mp_join(address, port, nick, password)
            await MainActor.run {
                self.isBusy = false
                if Int(r) == Int(AZ_MP_OK) {
                    self.chat.removeAll()
                    self.refreshRoomInfo()
                } else {
                    self.lastError = Self.describe(Int(r))
                }
            }
        }
    }

    func leave() {
        lan.stopAdvertising()
        az_mp_leave()
        isHosting = false
        state = az_mp_state()
        members = []
        roomName = ""
    }

    func send(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        az_mp_send_chat(trimmed)
        // The room does not echo our own messages back (same as Azahar's desktop chat), so show
        // them right away, or the sender never sees what they wrote.
        chat.append(ChatLine(nickname: AppSettings.shared.nickname, text: trimmed, isSystem: false))
    }

    func kick(_ m: Member) { az_mp_kick(m.nickname) }
    func ban(_ m: Member) { az_mp_ban(m.nickname) }

    func refreshLobby() {
        let url = AppSettings.shared.lobbyURL
        guard !url.isEmpty else {
            lobbyRooms = []
            lobbyError = "未设置大厅服务器地址（设置 › 联机）"
            return
        }
        ensureInit()
        lobbyError = nil
        Task.detached {
            let p = az_lobby_fetch(url)
            let json = p.map { String(cString: $0) }
            az_free(p)
            await MainActor.run {
                guard let json else {
                    self.lobbyError = "无法连接大厅服务器"
                    return
                }
                let rooms = (try? JSONDecoder().decode([LobbyRoom].self, from: Data(json.utf8))) ?? []
                self.lobbyRooms = rooms.sorted { $0.members.count > $1.members.count }
            }
        }
    }

    // MARK: Events

    fileprivate func handle(event: AZMultiplayerEvent, message: String) {
        switch event {
        case AZ_MP_EVENT_STATE_CHANGED:
            state = AZMultiplayerState(rawValue: UInt32(message) ?? 0)
            if state == AZ_MP_STATE_IDLE {
                isHosting = az_mp_is_hosting()
                members = []
                lan.stopAdvertising()
            }
            refreshRoomInfo()
        case AZ_MP_EVENT_ERROR:
            lastError = Self.describeError(name: message)
        case AZ_MP_EVENT_CHAT:
            struct Chat: Decodable { let nickname: String; let message: String }
            if let c = try? JSONDecoder().decode(Chat.self, from: Data(message.utf8)) {
                chat.append(ChatLine(nickname: c.nickname, text: c.message, isSystem: false))
            }
        case AZ_MP_EVENT_MEMBER_JOINED:
            chat.append(ChatLine(nickname: message, text: "\(message) 加入了房间", isSystem: true))
            refreshRoomInfo()
        case AZ_MP_EVENT_MEMBER_LEFT:
            chat.append(ChatLine(nickname: message, text: "\(message) 离开了房间", isSystem: true))
            refreshRoomInfo()
        case AZ_MP_EVENT_MEMBER_KICKED:
            chat.append(ChatLine(nickname: message, text: "\(message) 被踢出", isSystem: true))
            refreshRoomInfo()
        case AZ_MP_EVENT_MEMBER_BANNED:
            chat.append(ChatLine(nickname: message, text: "\(message) 被封禁", isSystem: true))
            refreshRoomInfo()
        case AZ_MP_EVENT_ROOM_INFO_CHANGED:
            refreshRoomInfo()
        case AZ_MP_EVENT_ANNOUNCE_ERROR:
            lastError = "公开到大厅失败：\(message)（房间仍可通过 IP 加入）"
        default:
            break
        }
    }

    func refreshRoomInfo() {
        state = az_mp_state()
        guard let p = az_mp_room_info() else { return }
        let json = String(cString: p)
        az_free(p)
        guard let info = try? JSONDecoder().decode(RoomInfo.self, from: Data(json.utf8)) else { return }
        roomName = info.name ?? ""
        members = info.members ?? []
        if isHosting {
            lan.updatePlayers(members.count)
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case Int(AZ_MP_ERR_ALREADY_IN_ROOM): return "已经在一个房间里了。"
        case Int(AZ_MP_ERR_CREATE_ROOM): return "无法创建房间（端口可能被占用）。"
        case Int(AZ_MP_ERR_COULD_NOT_CONNECT): return "连接不上房间。检查地址、端口和对方的防火墙/端口转发。"
        case Int(AZ_MP_ERR_WRONG_PASSWORD): return "密码错误。"
        case Int(AZ_MP_ERR_NAME_COLLISION): return "房间里已有人使用这个昵称。"
        case Int(AZ_MP_ERR_ROOM_FULL): return "房间已满。"
        case Int(AZ_MP_ERR_WRONG_VERSION): return "房间的联机协议版本与本模拟器不同。"
        case Int(AZ_MP_ERR_BANNED): return "你被这个房间封禁了。"
        case Int(AZ_MP_ERR_INVALID_NAME): return "昵称需 4–20 个字符，房间名需 3–20 个字符。"
        case Int(AZ_MP_ERR_CONSOLE_ID_COLLISION): return "房间里有人和你的虚拟主机 ID 相同（多见于复制了同一份 NAND）。"
        case Int(AZ_MP_ERR_MAC_COLLISION): return "房间里有人和你的 MAC 地址相同。"
        case Int(AZ_MP_ERR_TIMEOUT): return "连接超时。"
        default: return "网络错误。"
        }
    }

    static func describeError(name: String) -> String {
        switch name {
        case "LostConnection": return "与房间的连接断开了。"
        case "HostKicked": return "你被房主踢出了房间。"
        case "PermissionDenied": return "没有权限执行这个操作。"
        case "NoSuchUser": return "找不到这个玩家。"
        default: return describe(errorCode(name))
        }
    }

    private static func errorCode(_ name: String) -> Int {
        switch name {
        case "WrongPassword": return Int(AZ_MP_ERR_WRONG_PASSWORD)
        case "NameCollision": return Int(AZ_MP_ERR_NAME_COLLISION)
        case "RoomIsFull": return Int(AZ_MP_ERR_ROOM_FULL)
        case "WrongVersion": return Int(AZ_MP_ERR_WRONG_VERSION)
        case "HostBanned": return Int(AZ_MP_ERR_BANNED)
        case "CouldNotConnect": return Int(AZ_MP_ERR_COULD_NOT_CONNECT)
        case "ConsoleIdCollision": return Int(AZ_MP_ERR_CONSOLE_ID_COLLISION)
        case "MacCollision": return Int(AZ_MP_ERR_MAC_COLLISION)
        default: return Int(AZ_MP_ERR_NETWORK)
        }
    }
}

private let multiplayerCallback: AZMultiplayerCallback = { event, message, _ in
    let text = message.map { String(cString: $0) } ?? ""
    Task { @MainActor in MultiplayerManager.shared.handle(event: event, message: text) }
}
