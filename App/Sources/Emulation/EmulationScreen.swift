import AzaharCore
import SwiftUI

/// Full-screen game view: surface, virtual controls, overlay menu.
struct EmulationScreen: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var core = EmulatorCore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var input = InputManager.shared
    @ObservedObject private var mp = MultiplayerManager.shared

    @State private var showMenu = false
    @State private var showMultiplayer = false
    @State private var showStates = false
    @State private var startedSession = false
    /// Set when leaving the foreground paused a running game, so the pause menu can be shown on
    /// return — otherwise the game would just sit frozen with nothing telling the player why.
    @State private var pausedByInterruption = false
    @State private var toast: String?

    private var showController: Bool {
        !(settings.hideControllerWithGamepad && input.hasGamepad)
    }

    var body: some View {
        ZStack(alignment: .top) {
            EmulatorSurface(showController: showController) {
                guard !startedSession else { return }
                startedSession = true
                core.start(game)
                #if DEBUG
                AutoTest.sessionStarted(core: core)
                #endif
            }
            // Keep the top safe area (Dynamic Island / status bar) free in portrait; in landscape
            // there is no top inset, so the screens still use the full height.
            .ignoresSafeArea(.container, edges: [.bottom, .horizontal])

            HStack(spacing: 12) {
                Button { openMenu() } label: {
                    Image(systemName: "line.3.horizontal.circle.fill")
                        .font(.system(size: 28)).symbolRenderingMode(.hierarchical)
                }
                if core.isFastForward {
                    Label("快进", systemImage: "forward.fill").font(.caption.bold())
                        .padding(6).background(.ultraThinMaterial, in: Capsule())
                }
                if mp.state != AZ_MP_STATE_IDLE {
                    Label(mp.roomName.isEmpty ? "联机中" : mp.roomName, systemImage: "person.2.wave.2.fill")
                        .font(.caption.bold()).padding(6).background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Text(String(format: "%.0f FPS · %.0f%%", core.perf.game_fps, core.perf.emulation_speed * 100))
                    .font(.caption.monospacedDigit()).padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(core.state == .running ? 1 : 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.top, 4)

            if case .loading(let stage, let progress) = core.state {
                LoadingOverlay(stage: stage, progress: progress, title: game.title)
            }
            if let toast {
                Text(toast).font(.callout).padding(10).background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 50).transition(.opacity)
            }
        }
        .background(Color.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            InputManager.shared.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            InputManager.shared.stop()
            core.stop()
        }
        .onChange(of: scenePhase) { phase in
            #if DEBUG
            if RemotePlay.enabled { RemotePlay.log("scenePhase \(phase) state=\(core.state) menu=\(showMenu)") }
            #endif
            if phase != .active {
                // iOS forbids GPU work in the background: always pause before leaving the foreground.
                if core.state == .running { pausedByInterruption = true }
                core.setPaused(true)
            } else if pausedByInterruption {
                pausedByInterruption = false
                if !showMenu { showMenu = true } // stays paused until "继续"
            }
        }
        .onChange(of: core.state) { state in
            if case .idle = state, startedSession { dismiss() }
            // The pause menu means "paused": if something else resumed the game, close it.
            if case .running = state, showMenu { showMenu = false }
        }
        .onChange(of: showMenu) { shown in
            #if DEBUG
            if RemotePlay.enabled { RemotePlay.log("pause menu \(shown ? "shown" : "dismissed")") }
            #endif
        }
        .confirmationDialog(game.title, isPresented: $showMenu, titleVisibility: .visible) {
            Button("继续") { core.setPaused(false) }
            Button(core.isFastForward ? "关闭快进" : "快进 \(settings.fastForwardSpeed)%") {
                core.isFastForward.toggle(); core.setPaused(false)
            }
            Button("即时存档 / 读档") { showStates = true }
            Button("交换上下屏") {
                settings.swapScreens.toggle()
                az_swap_screens(settings.swapScreens)
                core.setPaused(false)
            }
            Button("画面布局：\(settings.landscapeLayout.title)") {
                let all = AppSettings.ScreenLayout.allCases
                let next = all[(all.firstIndex(of: settings.landscapeLayout)! + 1) % all.count]
                settings.landscapeLayout = next
                az_set_layout(Int32(next.rawValue), UIScreen.main.bounds.height > UIScreen.main.bounds.width)
                core.setPaused(false)
                show("布局：\(next.title)")
            }
            Button("截图") {
                core.setPaused(false)
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let url = await core.screenshot()
                    show(url != nil ? "截图已保存到 文件 › Bifold › Azahar › screenshots" : "截图失败")
                }
            }
            Button("联机") { showMultiplayer = true }
            Button("退出游戏", role: .destructive) { core.stop() }
            Button("取消", role: .cancel) { core.setPaused(false) }
        }
        .sheet(isPresented: $showMultiplayer, onDismiss: { core.setPaused(false) }) {
            NavigationStack { MultiplayerView(inGame: game) }
        }
        .sheet(isPresented: $showStates, onDismiss: { core.setPaused(false) }) {
            SaveStatesView { slot, save in
                showStates = false
                core.setPaused(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if save { core.saveState(slot: slot); show("已存档到位置 \(slot)") }
                    else { core.loadState(slot: slot); show("已读取位置 \(slot)") }
                }
            }
        }
        .alert("无法运行", isPresented: Binding(get: { if case .failed = core.state { return true }; return false },
                                              set: { if !$0 { dismiss() } })) {
            Button("好") { dismiss() }
        } message: {
            if case .failed(let message) = core.state { Text(message) }
        }
    }

    private func openMenu() {
        core.setPaused(true)
        showMenu = true
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { toast = nil } }
    }
}

private struct LoadingOverlay: View {
    let stage: Int
    let progress: Double
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: stage >= 2 ? progress : nil)
                .progressViewStyle(.linear).frame(maxWidth: 260)
            Text(title).font(.headline)
            Text(stage >= 2 ? "正在加载着色器缓存…" : "正在启动…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}

struct SaveStatesView: View {
    let action: (Int, Bool) -> Void
    @State private var states: [SaveStateInfo] = []

    var body: some View {
        NavigationStack {
            List {
                Section("位置") {
                    ForEach(1...10, id: \.self) { slot in
                        let info = states.first { $0.slot == slot }
                        HStack {
                            VStack(alignment: .leading) {
                                Text("位置 \(slot)")
                                Text(info.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "空")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("存档") { action(slot, true) }.buttonStyle(.bordered)
                            Button("读档") { action(slot, false) }.buttonStyle(.borderedProminent)
                                .disabled(info == nil)
                        }
                    }
                }
                Section {
                    Text("即时存档依赖模拟器版本。更新应用后旧存档可能无法读取，请同时使用游戏内存档。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("即时存档")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { states = EmulatorCore.shared.saveStates() }
        }
    }
}
