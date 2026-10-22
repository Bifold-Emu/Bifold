import AzaharCore
import SwiftUI

/// Full-screen game view: surface, virtual controls, status bar and the pause panel.
struct EmulationScreen: View {
    let game: Game
    /// Save state to restore once the game is running (the library's "读取最新存档").
    var loadSlot: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var core = EmulatorCore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var input = InputManager.shared
    @ObservedObject private var mp = MultiplayerManager.shared

    @State private var showMenu = false
    @State private var showMultiplayer = false
    @State private var startedSession = false
    @State private var didLoadSlot = false
    /// Set when leaving the foreground paused a running game, so the pause panel can be shown on
    /// return — otherwise the game would just sit frozen with nothing telling the player why.
    @State private var pausedByInterruption = false
    /// Top screen as it was when the panel opened; becomes the picture of a slot saved from it.
    @State private var pausePicture: UIImage?
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

            statusBar

            if case .loading(let stage, let progress) = core.state {
                LoadingOverlay(stage: stage, progress: progress, game: game)
            }
            if let toast {
                Text(toast).font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.top, 54).transition(.opacity)
            }
            if showMenu {
                PausePanel(game: game, picture: pausePicture, actions: panelActions)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
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
                if !showMenu { pausePicture = nil; showPanel(true) } // stays paused until "继续游戏"
            }
        }
        .onChange(of: core.state) { state in
            if case .idle = state, startedSession { dismiss() }
            // The pause panel means "paused": if something else resumed the game, close it.
            if case .running = state, showMenu { showPanel(false) }
            #if DEBUG
            // -uiDemo pause: open the pause panel once the game has run a while (UI screenshots).
            if case .running = state, !didLoadSlot, UserDefaults.standard.string(forKey: "uiDemo") == "pause" {
                didLoadSlot = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { openMenu() }
            }
            #endif
            if case .running = state, let slot = loadSlot, !didLoadSlot {
                didLoadSlot = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    core.loadState(slot: slot)
                    show("已读取位置 \(slot)")
                }
            }
        }
        .onChange(of: showMenu) { shown in
            #if DEBUG
            if RemotePlay.enabled { RemotePlay.log("pause menu \(shown ? "shown" : "dismissed")") }
            #endif
        }
        .sheet(isPresented: $showMultiplayer, onDismiss: { resume() }) {
            NavigationStack { MultiplayerView(inGame: game) }
                .environment(\.colorScheme, .dark)
        }
        .alert("无法运行", isPresented: Binding(get: { if case .failed = core.state { return true }; return false },
                                              set: { if !$0 { dismiss() } })) {
            Button("好") { dismiss() }
        } message: {
            if case .failed(let message) = core.state { Text(message) }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Button { openMenu() } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.5), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15)))
            }
            .accessibilityLabel("暂停")
            if core.isFastForward {
                pill { Image(systemName: "forward.fill"); Text("\(settings.fastForwardSpeed)%") }
            }
            if mp.state != AZ_MP_STATE_IDLE {
                pill { Image(systemName: "person.2.wave.2.fill"); Text(mp.roomName.isEmpty ? "联机中" : mp.roomName).lineLimit(1) }
            }
            Spacer()
            if core.state == .running {
                pill {
                    StatusLight(color: JITHelper.isEnabled ? Theme.led : .orange)
                    Text(JITHelper.isEnabled ? "JIT" : "解释器")
                    Text(String(format: "%.0f fps", core.perf.game_fps)).monospacedDigit()
                    if core.perf.emulation_speed < 0.95 || core.isFastForward {
                        Text(String(format: "%.0f%%", core.perf.emulation_speed * 100)).monospacedDigit()
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5, content: content)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: Pause panel

    private var panelActions: PausePanel.Actions {
        PausePanel.Actions(
            resume: { resume() },
            toggleFastForward: { core.isFastForward.toggle(); resume() },
            screenshot: {
                resume()
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let url = await core.screenshot()
                    show(url != nil ? "截图已保存到 文件 › Bifold › Azahar › screenshots" : "截图失败")
                }
            },
            swapScreens: {
                settings.swapScreens.toggle()
                az_swap_screens(settings.swapScreens)
                resume()
            },
            cycleLayout: {
                let all = AppSettings.ScreenLayout.allCases
                let next = all[(all.firstIndex(of: settings.landscapeLayout)! + 1) % all.count]
                settings.landscapeLayout = next
                az_set_layout(Int32(next.rawValue), UIScreen.main.bounds.height > UIScreen.main.bounds.width)
                resume()
                show("横屏布局：\(next.title)")
            },
            save: { slot in
                let picture = pausePicture
                resume()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    core.saveState(slot: slot)
                    if let picture { PlayHistory.shared.storeSlotPicture(picture, game: game, slot: slot) }
                    else { try? FileManager.default.removeItem(at: PlayHistory.slotURL(game.titleIDString, slot)) }
                    show("已存到位置 \(slot)")
                }
            },
            load: { slot in
                resume()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    core.loadState(slot: slot)
                    show("已读取位置 \(slot)")
                }
            },
            multiplayer: { showPanel(false); showMultiplayer = true },
            quit: { core.stop() }
        )
    }

    private func openMenu() {
        guard !showMenu else { return }
        if core.state == .running {
            // Picture first (the renderer only takes it while frames are being presented).
            Task {
                pausePicture = await PlayHistory.shared.captureLastScene(for: game)
                core.setPaused(true)
                showPanel(true)
            }
        } else {
            core.setPaused(true)
            showPanel(true)
        }
    }

    private func showPanel(_ shown: Bool) {
        withAnimation(.easeOut(duration: 0.18)) { showMenu = shown }
    }

    private func resume() {
        showPanel(false)
        core.setPaused(false)
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { toast = nil } }
    }
}

/// The pause panel: resume, quick actions, the ten save-state slots with pictures, multiplayer,
/// quit. A bottom sheet in portrait; centred and narrower in landscape.
private struct PausePanel: View {
    struct Actions {
        let resume: () -> Void
        let toggleFastForward: () -> Void
        let screenshot: () -> Void
        let swapScreens: () -> Void
        let cycleLayout: () -> Void
        let save: (Int) -> Void
        let load: (Int) -> Void
        let multiplayer: () -> Void
        let quit: () -> Void
    }

    let game: Game
    let picture: UIImage?
    let actions: Actions

    @ObservedObject private var core = EmulatorCore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mp = MultiplayerManager.shared
    @ObservedObject private var history = PlayHistory.shared
    @State private var slots: [Int: Date] = [:]
    @State private var confirmQuit = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: landscape ? .center : .bottom) {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { actions.resume() }
                panel(landscape: landscape)
                    .frame(maxWidth: landscape ? 520 : .infinity)
                    .padding(landscape ? 16 : 0)
            }
        }
        .onAppear {
            slots = Dictionary(uniqueKeysWithValues: core.saveStates().map { ($0.slot, $0.date) })
        }
    }

    private func panel(landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !landscape {
                Capsule().fill(Theme.separator).frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 12)
            }
            HStack(spacing: 12) {
                GameIcon(game: game, size: 44, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已暂停").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(game.title).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            .padding(.bottom, 14)

            Button("继续游戏", action: actions.resume).buttonStyle(PrimaryButtonStyle(height: 52))

            HStack(spacing: 10) {
                quick(core.isFastForward ? "关闭快进" : "快进 \(settings.fastForwardSpeed)%", "forward.fill",
                      active: core.isFastForward, action: actions.toggleFastForward)
                quick("截图", "camera.fill", action: actions.screenshot)
                quick("交换上下屏", "arrow.up.arrow.down", action: actions.swapScreens)
                quick(settings.landscapeLayout.title, "rectangle.split.2x1", action: actions.cycleLayout)
            }
            .padding(.vertical, 14)

            HStack(alignment: .firstTextBaseline) {
                Text("即时存档").font(.system(size: 17, weight: .heavy, design: .rounded))
                Spacer()
                Text("点按读取 · 长按覆盖").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            .padding(.bottom, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    newSlotTile
                    ForEach(slots.sorted { $0.value > $1.value }, id: \.key) { slot, date in
                        slotTile(slot, date: date)
                    }
                }
                .padding(.trailing, 18)
            }
            .padding(.trailing, -18)

            VStack(spacing: 0) {
                Divider().overlay(Theme.separator)
                Button(action: actions.multiplayer) {
                    HStack {
                        Text("联机").font(.body.weight(.semibold))
                        Spacer()
                        Text(mp.isConnected ? (mp.roomName.isEmpty ? "已连接" : mp.roomName) : "未连接")
                            .foregroundStyle(Theme.secondaryText)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.separator)
                Button { confirmQuit = true } label: {
                    Text("退出游戏").font(.body.weight(.semibold)).foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog("退出游戏？", isPresented: $confirmQuit, titleVisibility: .visible) {
                    Button("退出", role: .destructive, action: actions.quit)
                } message: {
                    Text("没有保存的进度会丢失。需要时先用游戏内存档或即时存档。")
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, landscape ? 16 : 30)
        .padding(.top, landscape ? 18 : 0)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .ignoresSafeArea(edges: landscape ? [] : .bottom)
    }

    private func quick(_ title: String, _ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Theme.accent : .primary)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent, lineWidth: active ? 2 : 0))
        }
        .buttonStyle(.plain)
    }

    /// Saves to the first empty slot, or over the oldest one when all ten are used.
    private var newSlotTile: some View {
        let target = (1...10).first { slots[$0] == nil }
            ?? slots.min { $0.value < $1.value }?.key ?? 1
        return Button { actions.save(target) } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                Text("存到位置 \(target)").font(.system(size: 12, weight: .semibold))
                if slots[target] != nil {
                    Text("覆盖最早的").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
            .foregroundStyle(Theme.accent)
            .frame(width: 128, height: 118)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        .buttonStyle(.plain)
    }

    private func slotTile(_ slot: Int, date: Date) -> some View {
        let _ = history.pictureVersion
        let pic = UIImage(contentsOfFile: PlayHistory.slotURL(game.titleIDString, slot).path)
        return Button { actions.load(slot) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let pic {
                        Image(uiImage: pic).resizable().scaledToFill()
                    } else {
                        ZStack { Theme.raised; Image(systemName: "photo").foregroundStyle(Theme.secondaryText) }
                    }
                }
                .frame(width: 128, height: 77)
                .clipped()
                VStack(alignment: .leading, spacing: 1) {
                    Text("位置 \(slot)").font(.system(size: 12.5, weight: .bold))
                    Text(date.shortPlayedText).font(.caption2).foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(width: 128, height: 118, alignment: .top)
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { actions.load(slot) } label: { Label("读取", systemImage: "arrow.counterclockwise") }
            Button { actions.save(slot) } label: { Label("存到这里（覆盖）", systemImage: "square.and.arrow.down") }
        }
    }
}

private struct LoadingOverlay: View {
    let stage: Int
    let progress: Double
    let game: Game

    var body: some View {
        VStack(spacing: 14) {
            GameIcon(game: game, size: 64, radius: 14)
            Text(game.title).font(.system(size: 17, weight: .bold, design: .rounded))
            ProgressView(value: stage >= 2 ? progress : nil)
                .progressViewStyle(.linear).tint(Theme.accent).frame(width: 220)
            Text(stage >= 2 ? "正在加载着色器缓存" : "正在启动").font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .padding(28)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
