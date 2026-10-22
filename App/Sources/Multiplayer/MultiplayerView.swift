import AzaharCore
import SwiftUI

/// Lobby / LAN / direct connect / host, and the room screen once connected.
struct MultiplayerView: View {
    var inGame: Game? = nil
    @ObservedObject private var mp = MultiplayerManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var lan = MultiplayerManager.shared.lan
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case lobby = "公共大厅", lan = "局域网", direct = "直连", host = "创建房间"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .lan
    @State private var directAddress = ""
    @State private var directPort = "24872"
    @State private var password = ""
    @State private var passwordPrompt: (address: String, port: UInt16)?
    @State private var hostName = ""
    @State private var hostPort = "24872"
    @State private var hostPassword = ""
    @State private var hostMax = 4
    @State private var hostPublic = false

    var body: some View {
        Group {
            if mp.isConnected {
                RoomView()
            } else {
                browser
            }
        }
        .navigationTitle(mp.isConnected ? (mp.roomName.isEmpty ? "房间" : mp.roomName) : "联机")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
        }
        .alert("联机", isPresented: Binding(get: { mp.lastError != nil }, set: { if !$0 { mp.lastError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(mp.lastError ?? "") }
        .alert("房间密码", isPresented: Binding(get: { passwordPrompt != nil }, set: { if !$0 { passwordPrompt = nil } })) {
            SecureField("密码", text: $password)
            Button("加入") {
                if let p = passwordPrompt { mp.join(address: p.address, port: p.port, password: password) }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            if hostName.isEmpty { hostName = String("\(settings.nickname) 的房间".prefix(20)) }
            if settings.lanDiscovery { lan.startBrowsing() }
            if !settings.lobbyURL.isEmpty { tab = .lobby; mp.refreshLobby() }
        }
        .onDisappear { lan.stopBrowsing() }
    }

    private var browser: some View {
        Form {
            Section {
                Picker("方式", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("昵称") {
                    TextField("4–20 个字符", text: $settings.nickname)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text("联机模拟的是 3DS 的本地无线通信（如精灵宝可梦交换/对战、怪物猎人联机）。所有人需运行同一游戏、同一版本。与电脑/安卓上的 Azahar 互通。")
            }

            switch tab {
            case .lobby: lobbySection
            case .lan: lanSection
            case .direct: directSection
            case .host: hostSection
            }
        }
        .disabled(mp.isBusy)
        .overlay { if mp.isBusy { ProgressView("连接中…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    // MARK: Sections

    @ViewBuilder private var lobbySection: some View {
        Section {
            if let err = mp.lobbyError {
                Text(err).foregroundStyle(.secondary)
            }
            ForEach(mp.lobbyRooms) { room in
                Button {
                    join(room.address, room.port, needsPassword: room.has_password)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(room.name).font(.headline)
                            if room.has_password { Image(systemName: "lock.fill").font(.caption) }
                            Spacer()
                            Text("\(room.members.count)/\(room.max_players)").monospacedDigit()
                        }
                        Text(room.preferred_game.isEmpty ? "任意游戏" : room.preferred_game)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !room.compatible {
                            Text("协议版本不兼容").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .disabled(!room.compatible)
            }
        } header: {
            HStack {
                Text(settings.lobbyURL.isEmpty ? "大厅" : settings.lobbyURL)
                Spacer()
                Button { mp.refreshLobby() } label: { Image(systemName: "arrow.clockwise") }
            }
        } footer: {
            Text("在 设置 › 联机 中填写自建大厅服务器的地址（例如 http://你的服务器:5000）。见 Server/README.md。")
        }
    }

    @ViewBuilder private var lanSection: some View {
        Section {
            if !settings.lanDiscovery {
                Text("已在设置中关闭局域网发现。").foregroundStyle(.secondary)
            } else if lan.rooms.isEmpty {
                HStack { ProgressView(); Text("正在搜索同一 Wi-Fi 下的房间…").foregroundStyle(.secondary) }
            }
            ForEach(lan.rooms) { room in
                Button {
                    join(room.addresses.first ?? "", room.port, needsPassword: room.hasPassword)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(room.name).font(.headline)
                            if room.hasPassword { Image(systemName: "lock.fill").font(.caption) }
                            Spacer()
                            Text("\(room.players)/\(room.maxPlayers)").monospacedDigit()
                        }
                        Text("\(room.host) · \(room.game.isEmpty ? "任意游戏" : room.game)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("同一 Wi-Fi（或连接到房主的个人热点）即可自动发现，不需要输入 IP。首次使用时请允许“本地网络”权限。")
        }
    }

    @ViewBuilder private var directSection: some View {
        Section {
            TextField("房间地址（IP 或域名）", text: $directAddress)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("端口", text: $directPort).keyboardType(.numberPad)
            SecureField("密码（可选）", text: $password)
            Button("加入房间") {
                mp.join(address: directAddress.trimmingCharacters(in: .whitespaces),
                        port: UInt16(directPort) ?? az_mp_default_port(), password: password)
            }
            .disabled(directAddress.isEmpty)
        } footer: {
            Text("可加入任何 Azahar 房间：电脑/安卓玩家开的房间，或在 VPS 上运行的 azahar-room 专用服务器。")
        }
    }

    @ViewBuilder private var hostSection: some View {
        Section {
            TextField("房间名（3–20 个字符）", text: $hostName)
            TextField("端口", text: $hostPort).keyboardType(.numberPad)
            SecureField("密码（可选）", text: $hostPassword)
            Stepper("最多 \(hostMax) 人", value: $hostMax, in: 2...16)
            Toggle("公开到大厅", isOn: $hostPublic).disabled(settings.lobbyURL.isEmpty)
            Button("创建并加入") {
                mp.host(name: hostName, port: UInt16(hostPort) ?? az_mp_default_port(), password: hostPassword,
                        maxPlayers: hostMax, isPublic: hostPublic, preferredGame: inGame)
            }
        } footer: {
            Text("房间运行在这台设备上。同一 Wi-Fi 的玩家会自动发现它；外网玩家需要你的路由器把 UDP \(hostPort) 端口转发到这台设备，或者改用 VPS 上的专用服务器（更稳定，推荐）。")
        }
    }

    private func join(_ address: String, _ port: UInt16, needsPassword: Bool) {
        if needsPassword {
            password = ""
            passwordPrompt = (address, port)
        } else {
            mp.join(address: address, port: port, password: "")
        }
    }
}

/// Members + chat of the current room.
struct RoomView: View {
    @ObservedObject private var mp = MultiplayerManager.shared
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("成员 \(mp.members.count)") {
                    ForEach(mp.members) { m in
                        HStack {
                            Image(systemName: "person.fill")
                            VStack(alignment: .leading) {
                                Text(m.nickname)
                                Text(m.game.isEmpty ? "未在游戏中" : m.game).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mp.isModerator && m.nickname != AppSettings.shared.nickname {
                                Menu {
                                    Button("踢出") { mp.kick(m) }
                                    Button("封禁", role: .destructive) { mp.ban(m) }
                                } label: { Image(systemName: "ellipsis.circle") }
                            }
                        }
                    }
                }
                Section("聊天") {
                    ForEach(mp.chat) { line in
                        if line.isSystem {
                            Text(line.text).font(.caption).foregroundStyle(.secondary)
                        } else {
                            (Text(line.nickname).bold() + Text("：" + line.text)).font(.callout)
                        }
                    }
                }
                Section {
                    Button(mp.isHosting ? "关闭房间" : "离开房间", role: .destructive) { mp.leave() }
                }
            }
            HStack {
                TextField("发送消息", text: $message).textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("发送", action: send).disabled(message.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }

    private func send() {
        mp.send(message)
        message = ""
    }
}
