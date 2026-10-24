import SwiftUI
import UniformTypeIdentifiers

/// What to open: a game, optionally restoring one of its save states right after it boots.
struct PlayRequest: Identifiable {
    let game: Game
    var loadSlot: Int? = nil
    var id: String { game.id + "#\(loadSlot ?? 0)" }
}

/// App root: three tabs, and the game screen over all of them.
struct RootView: View {
    enum Tab: Hashable { case games, multiplayer, settings }

    @ObservedObject private var library = GameLibrary.shared
    @State private var tab: Tab = .games
    @State private var playing: PlayRequest?

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(play: { playing = $0 })
                .tabItem { Label("游戏", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.games)
            NavigationStack { MultiplayerView(isTab: true) }
                .tabItem { Label("联机", systemImage: "person.2.wave.2.fill") }
                .tag(Tab.multiplayer)
            NavigationStack { SettingsView(isTab: true) }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .fullScreenCover(item: $playing, onDismiss: { library.refresh() }) { req in
            EmulationScreen(game: req.game, loadSlot: req.loadSlot)
        }
        .onAppear {
            #if DEBUG
            AutoTest.waitForBootGame(in: library) { playing = PlayRequest(game: $0) }
            RemotePlay.startIfRequested()
            // -uiDemo settings|multiplayer: open a tab at launch (UI screenshots).
            switch UserDefaults.standard.string(forKey: "uiDemo") {
            case "settings", "bundled": tab = .settings
            case "multiplayer": tab = .multiplayer
            default: break
            }
            #endif
        }
    }
}

struct LibraryView: View {
    let play: (PlayRequest) -> Void
    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var history = PlayHistory.shared
    @State private var showImporter = false
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14)]

    private var filtered: [Game] {
        search.isEmpty ? library.games : library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var mine: [Game] { filtered.filter { !$0.isBundled } }
    private var bundled: [Game] { filtered.filter { $0.isBundled } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty, let recent = history.mostRecent(in: library.games) {
                        ContinueCard(game: recent, play: play)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                    let ownGames = library.games.contains { !$0.isBundled }
                    if !ownGames && !library.isScanning && search.isEmpty {
                        EmptyLibraryView { showImporter = true }
                            .padding(.top, library.games.isEmpty ? 40 : 12)
                    }
                    if !mine.isEmpty {
                        header(bundled.isEmpty ? "全部游戏" : "我的游戏", count: mine.count)
                        grid(mine)
                    }
                    if !bundled.isEmpty {
                        header("预置自制游戏", count: bundled.count,
                               note: "开源免费的自制游戏，可以长按从游戏库移除")
                            .id("bundledSection")
                        grid(bundled)
                    }
                }
            }
            #if DEBUG
            .onAppear {
                // -uiDemo bundledlib: scroll to the bundled games (UI screenshots).
                if UserDefaults.standard.string(forKey: "uiDemo") == "bundledlib" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { proxy.scrollTo("bundledSection", anchor: .top) }
                }
            }
            #endif
            }
            .pageBackground()
            .refreshable { library.refresh() }
            .searchable(text: $search, prompt: "搜索游戏")
            .navigationTitle("游戏")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("导入游戏")
                }
            }
            .overlay(alignment: .bottom) { banners }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: GameLibrary.importTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
            .onAppear { library.refresh() }
        }
    }

    private func header(_ title: String, count: Int, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 20, weight: .heavy, design: .rounded))
                Spacer()
                Text("\(count) 个").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            if let note { Text(note).font(.footnote).foregroundStyle(Theme.secondaryText) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    private func grid(_ games: [Game]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(games) { game in
                Button { play(PlayRequest(game: game)) } label: { GameCard(game: game) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: game) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func menu(for game: Game) -> some View {
        if let b = game.bundled {
            Text("\(b.author) · \(b.license)")
            if let url = URL(string: b.source) {
                Link(destination: url) { Label("源代码", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            Button(role: .destructive) { library.delete(game) } label: { Label("从游戏库移除", systemImage: "eye.slash") }
        } else {
            Text(game.titleIDString)
            Text(game.fileType)
            if let v = game.updateVersion { Text("已安装更新 \(Game.versionString(v))") }
            if game.hasDLC { Text("已安装 DLC") }
            if !game.isInstalledTitle {
                Button("删除", role: .destructive) { library.delete(game) }
            }
        }
    }

    private var banners: some View {
        VStack(spacing: 10) {
            if let p = library.installProgress {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在安装 \(library.installingName ?? "CIA")").font(.subheadline.weight(.semibold)).lineLimit(1)
                    ProgressView(value: p).tint(Theme.accent)
                }
                .padding(14)
                .frame(maxWidth: 420)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
            if let notice = library.notice {
                // A banner rather than an alert: an alert presented by a background
                // import would block opening a game the user just tapped.
                Label(notice, systemImage: "tray.and.arrow.down.fill")
                    .font(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .onTapGesture { library.dismissNotice() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("library.notice")
            }
        }
        .padding()
        .animation(.easeOut(duration: 0.2), value: library.notice)
    }
}

/// The game the player was last in, with where they left off.
private struct ContinueCard: View {
    let game: Game
    let play: (PlayRequest) -> Void
    @ObservedObject private var history = PlayHistory.shared

    var body: some View {
        let states = history.saveStates(of: game)
        VStack(spacing: 0) {
            scene
                .frame(maxWidth: .infinity)
                .aspectRatio(5 / 3, contentMode: .fit)
                .clipped()
            Hinge(height: 12)
            HStack(spacing: 12) {
                GameIcon(game: game, size: 52, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(detail).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            HStack(spacing: 10) {
                Button("继续游戏") { play(PlayRequest(game: game)) }
                    .buttonStyle(PrimaryButtonStyle(height: 46))
                if let newest = states.first {
                    Button("读取最新存档") { play(PlayRequest(game: game, loadSlot: newest.slot)) }
                        .buttonStyle(SecondaryButtonStyle(height: 46))
                }
            }
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var detail: String {
        guard let e = history.entry(for: game) else { return "" }
        return e.seconds > 30 ? "\(e.lastPlayed.shortPlayedText)  已玩 \(e.seconds.playTimeText)" : e.lastPlayed.shortPlayedText
    }

    @ViewBuilder private var scene: some View {
        let _ = history.pictureVersion
        if let img = UIImage(contentsOfFile: PlayHistory.lastSceneURL(game.historyKey).path) {
            Image(uiImage: img).resizable().interpolation(.medium).scaledToFill()
        } else {
            ZStack {
                BlurredIcon(game: game)
                GameIcon(game: game, size: 96, radius: 20).shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            }
        }
    }
}

private struct GameCard: View {
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                BlurredIcon(game: game)
                GameIcon(game: game, size: nil, radius: 12)
                    .padding(18)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if game.isBundled {
                    Text("预置").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if game.encrypted {
                    Image(systemName: "lock.fill").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(6).background(Theme.danger, in: Circle()).padding(6)
                        .accessibilityLabel("已加密")
                }
            }
            Hinge(height: 7, knuckleInset: 0.22)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = subtitle {
                    Text(sub).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
    }

    private var subtitle: String? {
        let parts = [game.updateVersion.map { "更新 \(Game.versionString($0))" }, game.hasDLC ? "DLC" : nil].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: "  ") }
        if let b = game.bundled { return b.author }
        return game.isInstalledTitle ? nil : game.fileType
    }
}

/// The game's 48×48 SMDH icon, or a placeholder.
struct GameIcon: View {
    let game: Game
    var size: CGFloat?
    var radius: CGFloat

    var body: some View {
        Group {
            if let icon = game.icon {
                Image(uiImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                ZStack {
                    Theme.raised
                    Image(systemName: "gamecontroller.fill").font(.title2).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The icon blown up and blurred: a colour field that belongs to the game.
private struct BlurredIcon: View {
    let game: Game
    var body: some View {
        GeometryReader { geo in
            if let icon = game.icon {
                Image(uiImage: icon).resizable().scaledToFill()
                    .frame(width: geo.size.width * 1.4, height: geo.size.height * 1.4)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .blur(radius: 18).saturation(1.3).opacity(0.85)
            } else {
                Theme.raised
            }
        }
        .background(Theme.raised)
    }
}

private struct EmptyLibraryView: View {
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("放入你的第一个游戏").font(.system(size: 24, weight: .heavy, design: .rounded))
            Text("用从你自己的 3DS 卡带或主机导出的游戏文件：.3ds、.cci、.cxi、.3dsx 或 .cia。")
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 10) {
                Label("在这台手机上：「文件」App › 我的 iPhone › Bifold", systemImage: "folder.fill")
                Label("在电脑上：Finder（Mac）或 Apple Devices / iTunes（Windows）的文件共享", systemImage: "laptopcomputer")
                Label(".cia 会自动安装，包括游戏的更新和 DLC", systemImage: "shippingbox.fill")
            }
            .font(.subheadline)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            Button("从「文件」选取", action: importAction).buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 20)
    }
}
