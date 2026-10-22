import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var core = EmulatorCore.shared
    @State private var showImporter = false
    @State private var playing: Game?
    @State private var search = ""
    @State private var showMultiplayer = false
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 16)]

    private var filtered: [Game] {
        search.isEmpty ? library.games : library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.games.isEmpty && !library.isScanning {
                    EmptyLibraryView { showImporter = true }
                        .padding(.top, 60)
                }
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(filtered) { game in
                        Button { playing = game } label: { GameTile(game: game) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Text(game.titleIDString)
                                Text(game.fileType)
                                if let v = game.updateVersion { Text("已安装更新 \(Game.versionString(v))") }
                                if game.hasDLC { Text("已安装 DLC") }
                                if !game.isInstalledTitle {
                                    Button("删除", role: .destructive) { library.delete(game) }
                                }
                            }
                    }
                }
                .padding()
            }
            .refreshable { library.refresh() }
            .searchable(text: $search, prompt: "搜索游戏")
            .navigationTitle("游戏")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showMultiplayer = true } label: { Image(systemName: "person.2.wave.2") }
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if let p = library.installProgress {
                        VStack {
                            Text("正在安装 \(library.installingName ?? "CIA")…").lineLimit(1)
                            ProgressView(value: p).frame(width: 220)
                        }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let notice = library.notice {
                        // A banner rather than an alert: an alert presented by a background
                        // import would block opening a game the user just tapped.
                        Label(notice, systemImage: "tray.and.arrow.down.fill")
                            .font(.subheadline)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: 420, alignment: .leading)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .onTapGesture { library.dismissNotice() }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityIdentifier("library.notice")
                    }
                }
                .padding()
                .animation(.easeOut(duration: 0.2), value: library.notice)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: GameLibrary.importTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
            .fullScreenCover(item: $playing, onDismiss: { library.refresh() }) { game in
                EmulationScreen(game: game)
            }
            .sheet(isPresented: $showMultiplayer) { NavigationStack { MultiplayerView() } }
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
            .onAppear {
                library.refresh()
                #if DEBUG
                AutoTest.waitForBootGame(in: library) { playing = $0 }
                RemotePlay.startIfRequested()
                #endif
            }
        }
    }
}

private struct GameTile: View {
    let game: Game

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon = game.icon {
                    Image(uiImage: icon).resizable().interpolation(.high)
                } else {
                    ZStack {
                        LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if game.encrypted {
                    Image(systemName: "lock.fill").padding(4).background(.red, in: Circle())
                        .foregroundStyle(.white).font(.caption2).offset(x: 4, y: -4)
                }
            }
            .shadow(radius: 3, y: 2)
            Text(game.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: 110)
            if game.updateVersion != nil || game.hasDLC {
                Text([game.updateVersion.map { "更新 \(Game.versionString($0))" }, game.hasDLC ? "DLC" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyLibraryView: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("还没有游戏").font(.title3.bold())
            Text("导入你自己从 3DS 卡带或主机里导出的游戏文件（.3ds / .cci / .cxi / .3dsx / .cia）。\n也可以把文件放进 Bifold 文件夹：手机上用“文件”App（我的 iPhone › Bifold），电脑上用 Finder（Mac）或 iTunes / Apple Devices（Windows）的文件共享。.cia 会自动安装，包括游戏的更新和 DLC。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
            Button("导入游戏", action: importAction).buttonStyle(.borderedProminent)
        }
    }
}
