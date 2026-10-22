import AzaharCore
import Foundation
import QuartzCore
import UIKit

/// Swift façade over the AzaharCore C API. One instance for the whole app.
@MainActor
final class EmulatorCore: ObservableObject {
    static let shared = EmulatorCore()

    enum RunState: Equatable {
        case idle
        case loading(stage: Int, progress: Double)
        case running
        case paused
        case failed(String)
    }

    @Published private(set) var state: RunState = .idle
    @Published private(set) var perf = AZPerfStats()
    @Published private(set) var currentGame: Game?
    @Published var isFastForward = false {
        didSet { az_set_speed_override(isFastForward ? Double(AppSettings.shared.fastForwardSpeed) : 0) }
    }

    let userDirectory: URL
    private var emuThread: Thread?
    private var perfTimer: Timer?
    private(set) var isInitialized = false

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Visible in the Files app (UIFileSharingEnabled) so users can drop in sysdata / saves.
        userDirectory = docs.appendingPathComponent("Azahar", isDirectory: true)
    }

    // MARK: - Lifetime

    func initialize() {
        guard !isInitialized else { return }
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        // Tell oaknut (dynarmic's code emitter) which JIT memory strategy to use before any
        // JIT code block is allocated. See patches/oaknut/0001-ios-jit.patch.
        setenv("OAKNUT_IOS_JIT_MODE", AppSettings.shared.jitMode.environmentValue, 1)
        setenv("OAKNUT_IOS_JIT_ARENA_MB", "\(AppSettings.shared.jitArenaMB)", 1)
        #if DEBUG
        // Test hooks (launch arguments): -jitCacheMB 2 shrinks each dynarmic code cache so it is
        // wiped every few seconds; -noRsbReset YES disables the fix for wiping it mid-run.
        let d = UserDefaults.standard
        if d.integer(forKey: "jitCacheMB") > 0 { setenv("AZIOS_JIT_CACHE_MB", "\(d.integer(forKey: "jitCacheMB"))", 1) }
        if d.bool(forKey: "noRsbReset") { setenv("DYNARMIC_NO_RSB_RESET", "1", 1) }
        #endif

        AppSettings.shared.writeCoreConfig(to: userDirectory)

        let moltenVK = Bundle.main.privateFrameworksPath.map { "\($0)/MoltenVK.framework/MoltenVK" }
        isInitialized = az_init(userDirectory.path, moltenVK)

        MultiplayerManager.shared.ensureInit()
        az_set_keyboard_callback(coreKeyboardCallback, nil)
        az_set_loading_callback(coreLoadingCallback, nil)
    }

    fileprivate func loadingProgress(stage: Int, progress: Double) {
        if stage >= 4 {
            if case .loading = state { state = .running }
        } else {
            state = .loading(stage: stage, progress: progress)
        }
    }

    var coreVersion: String {
        guard let p = az_core_version() else { return "?" }
        defer { az_free(p) }
        return String(cString: p)
    }

    var jitStatus: AZJitStatus { az_jit_status() }

    func reloadSettings() {
        AppSettings.shared.writeCoreConfig(to: userDirectory)
        az_reload_settings()
    }

    // MARK: - Session

    func start(_ game: Game) {
        guard emuThread == nil else { return }
        reloadSettings()
        currentGame = game
        state = .loading(stage: 0, progress: 0)
        PlayHistory.shared.sessionStarted(game)

        let path = game.url.path
        let thread = Thread { [weak self] in
            let result = az_run_game(path)
            let details: String = {
                guard let p = az_last_error_details() else { return "" }
                defer { az_free(p) }
                return String(cString: p)
            }()
            Task { @MainActor in self?.sessionEnded(result: result, details: details) }
        }
        thread.name = "Azahar.Emu"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 16 << 20 // HLE services recurse deeply
        emuThread = thread
        thread.start()

        perfTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let core = EmulatorCore.shared
                var stats = AZPerfStats()
                if az_get_perf_stats(&stats) {
                    core.perf = stats
                    if case .loading = core.state, stats.system_fps > 0 { core.state = .running }
                }
            }
        }
    }

    private func sessionEnded(result: AZResult, details: String) {
        emuThread = nil
        PlayHistory.shared.sessionEnded()
        perfTimer?.invalidate()
        perfTimer = nil
        isFastForward = false
        switch result {
        case AZ_RESULT_SUCCESS, AZ_RESULT_SHUTDOWN_REQUESTED:
            state = .idle
        default:
            state = .failed(Self.describe(result, details: details))
        }
        currentGame = nil
    }

    func setPaused(_ paused: Bool, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        if RemotePlay.enabled { RemotePlay.log("setPaused(\(paused)) from \(file):\(line) state=\(state)") }
        #endif
        guard emuThread != nil else { return }
        az_pause(paused)
        state = paused ? .paused : .running
    }

    func stop() {
        // A keyboard applet may be blocking the emulation thread; release it first.
        KeyboardBridge.cancel()
        az_stop()
    }

    func saveState(slot: Int) { az_save_state(Int32(slot)) }
    func loadState(slot: Int) { az_load_state(Int32(slot)) }

    func saveStates() -> [SaveStateInfo] {
        guard let p = az_list_save_states() else { return [] }
        defer { az_free(p) }
        let data = Data(String(cString: p).utf8)
        return (try? JSONDecoder().decode([SaveStateInfo].self, from: data)) ?? []
    }

    /// Screenshot of both screens to `url` (needs the game running: the renderer takes it on its
    /// next presented frame). Waits off the main thread, up to ~2 s.
    func capture(to url: URL) async -> Bool {
        let path = url.path
        return await Task.detached { az_screenshot(path) }.value
    }

    /// Waits for the renderer off the main thread (up to ~2 s).
    func screenshot() async -> URL? {
        let dir = userDirectory.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
        let path = url.path
        let ok = await Task.detached { az_screenshot(path) }.value
        return ok ? url : nil
    }

    static func describe(_ result: AZResult, details: String) -> String {
        let base: String
        switch result {
        case AZ_RESULT_ERROR_GET_LOADER: base = "无法识别的游戏文件格式。"
        case AZ_RESULT_ERROR_ENCRYPTED: base = "游戏是加密的。Azahar 只支持解密后的游戏（.cci/.3ds 解密版或已安装的 CIA）。"
        case AZ_RESULT_ERROR_INVALID_FORMAT: base = "游戏文件已损坏或格式无效。"
        case AZ_RESULT_ERROR_SYSTEM_FILES: base = "缺少系统文件。请在设置 → 系统文件中导入从你自己的 3DS 导出的文件。"
        case AZ_RESULT_ERROR_VIDEO_CORE: base = "图形初始化失败（Vulkan/MoltenVK）。"
        case AZ_RESULT_ERROR_NO_SURFACE: base = "渲染画面尚未就绪，请重试。"
        case AZ_RESULT_ERROR_GBA_TITLE: base = "不支持 GBA 虚拟主机游戏。"
        case AZ_RESULT_ERROR_SYSTEM_MODE: base = "无法确定游戏需要的系统模式。"
        default: base = "模拟器出错。"
        }
        return details.isEmpty ? base : "\(base)\n\(details)"
    }
}

struct SaveStateInfo: Decodable, Identifiable {
    let slot: Int
    let time: TimeInterval
    var id: Int { slot }
    var date: Date { Date(timeIntervalSince1970: time) }
}

// MARK: - C callbacks (file scope so they are not actor-isolated)

private let coreKeyboardCallback: AZKeyboardCallback = { hint, maxLength, multiline, buttons, outButton, _ in
    KeyboardBridge.present(hint: hint.map { String(cString: $0) } ?? "",
                           maxLength: Int(maxLength), multiline: multiline,
                           buttonCount: Int(buttons), outButton: outButton)
}

private let coreLoadingCallback: AZLoadingCallback = { stage, value, total, _ in
    let progress = total > 0 ? Double(value) / Double(total) : 0
    Task { @MainActor in EmulatorCore.shared.loadingProgress(stage: Int(stage), progress: progress) }
}
