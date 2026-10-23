import Foundation
import SwiftUI

/// User-facing settings. App-only preferences live in UserDefaults; emulator settings are also
/// written to <Documents>/Azahar/config/ios-config.ini, which the core reads (keys are
/// Azahar's own setting names, so the file matches a desktop qt-config.ini).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum JITMode: String, CaseIterable, Identifiable {
        case auto, legacy, universal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "自动"
            case .legacy: return "传统（iOS 17/18、非 TXM 设备）"
            case .universal: return "StikDebug 通用脚本（iOS 26 TXM 设备）"
            }
        }
        var environmentValue: String { rawValue }
    }

    enum ScreenLayout: Int, CaseIterable, Identifiable {
        case stacked = 0, single = 1, largeSmall = 2, sideBySide = 3, hybrid = 4
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .stacked: return "上下排列"
            case .single: return "单屏"
            case .largeSmall: return "大屏 + 小屏"
            case .sideBySide: return "左右并排"
            case .hybrid: return "混合"
            }
        }
        /// Value of Settings::LayoutOption on non-Android builds
        /// (Default, SingleScreen, LargeScreen, SideScreen, SeparateWindows, HybridScreen, Custom).
        var coreValue: Int {
            switch self {
            case .stacked: return 0
            case .single: return 1
            case .largeSmall: return 2
            case .sideBySide: return 3
            case .hybrid: return 5
            }
        }
    }

    /// What the in-game status bar shows about speed (Settings → 开发者选项).
    enum PerfOverlay: Int, CaseIterable, Identifiable {
        case off = 0, fps = 1, detailed = 2
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "不显示"
            case .fps: return "只显示帧率"
            case .detailed: return "详细（JIT、帧率、速度、帧时间）"
            }
        }
        var shortTitle: String {
            switch self {
            case .off: return "性能信息关"
            case .fps: return "帧率"
            case .detailed: return "详细"
            }
        }
    }

    // MARK: Graphics
    @AppStorage("resolutionFactor") var resolutionFactor = 2 { willSet { objectWillChange.send() } }
    @AppStorage("asyncShaders") var asyncShaders = true { willSet { objectWillChange.send() } }
    @AppStorage("textureFilter") var textureFilter = 0 { willSet { objectWillChange.send() } }
    @AppStorage("linearFiltering") var linearFiltering = true { willSet { objectWillChange.send() } }
    @AppStorage("vsync") var vsync = true { willSet { objectWillChange.send() } }
    @AppStorage("accurateMul") var accurateMul = true { willSet { objectWillChange.send() } }
    @AppStorage("diskShaderCache") var diskShaderCache = true { willSet { objectWillChange.send() } }

    // MARK: Performance
    @AppStorage("cpuClock") var cpuClock = 100 { willSet { objectWillChange.send() } }
    /// "Auto": 50 % without JIT, 100 % with JIT. Measured on an iPhone 14 Pro Max: without JIT the
    /// interpreter keeps Pokémon Sun at full speed at 50 % (25 % starves its loading threads and
    /// freezes the picture at scene changes; 100 % runs at roughly half speed).
    @AppStorage("cpuClockAuto") var cpuClockAuto = true { willSet { objectWillChange.send() } }
    var effectiveCPUClock: Int { cpuClockAuto ? (JITHelper.isEnabled ? 100 : 50) : cpuClock }
    @AppStorage("frameLimit") var frameLimit = 100 { willSet { objectWillChange.send() } }
    @AppStorage("fastForwardSpeed") var fastForwardSpeed = 300 { willSet { objectWillChange.send() } }
    @AppStorage("jitMode") private var jitModeRaw = JITMode.auto.rawValue { willSet { objectWillChange.send() } }
    /// Delete a .cia after it was installed from the app's folder (default: keep it in
    /// Games/已安装的 CIA so nothing the user copied in disappears silently).
    @AppStorage("deleteCIAAfterInstall") var deleteCIAAfterInstall = false { willSet { objectWillChange.send() } }
    @AppStorage("jitArenaMB") var jitArenaMB = 384 { willSet { objectWillChange.send() } }
    var jitMode: JITMode {
        get { JITMode(rawValue: jitModeRaw) ?? .auto }
        set { jitModeRaw = newValue.rawValue }
    }

    // MARK: Developer
    @AppStorage("perfOverlay") private var perfOverlayRaw = PerfOverlay.off.rawValue { willSet { objectWillChange.send() } }
    var perfOverlay: PerfOverlay {
        get { PerfOverlay(rawValue: perfOverlayRaw) ?? .off }
        set { perfOverlayRaw = newValue.rawValue }
    }

    // MARK: Layout
    @AppStorage("landscapeLayout") private var landscapeLayoutRaw = ScreenLayout.sideBySide.rawValue { willSet { objectWillChange.send() } }
    @AppStorage("swapScreens") var swapScreens = false { willSet { objectWillChange.send() } }
    var landscapeLayout: ScreenLayout {
        get { ScreenLayout(rawValue: landscapeLayoutRaw) ?? .sideBySide }
        set { landscapeLayoutRaw = newValue.rawValue }
    }

    // MARK: Audio
    @AppStorage("volume") var volume = 1.0 { willSet { objectWillChange.send() } }
    @AppStorage("audioStretching") var audioStretching = true { willSet { objectWillChange.send() } }
    @AppStorage("lleAudio") var lleAudio = false { willSet { objectWillChange.send() } }

    // MARK: System
    @AppStorage("isNew3DS") var isNew3DS = true { willSet { objectWillChange.send() } }
    @AppStorage("region") var region = -1 { willSet { objectWillChange.send() } }
    @AppStorage("lleApplets") var lleApplets = false { willSet { objectWillChange.send() } }

    // MARK: Controls
    @AppStorage("controllerOpacity") var controllerOpacity = 0.75 { willSet { objectWillChange.send() } }
    @AppStorage("haptics") var haptics = true { willSet { objectWillChange.send() } }
    @AppStorage("motionControls") var motionControls = true { willSet { objectWillChange.send() } }
    @AppStorage("hideControllerWithGamepad") var hideControllerWithGamepad = true { willSet { objectWillChange.send() } }

    // MARK: Multiplayer
    @AppStorage("nickname") var nickname = "" { willSet { objectWillChange.send() } }
    @AppStorage("lobbyURL") var lobbyURL = "" { willSet { objectWillChange.send() } }
    @AppStorage("lobbyToken") var lobbyToken = "" { willSet { objectWillChange.send() } }
    @AppStorage("lanDiscovery") var lanDiscovery = true { willSet { objectWillChange.send() } }

    private init() {
        let d = UserDefaults.standard
        // Someone who already picked a CPU clock keeps it instead of the new automatic default.
        // (Saved values only: test launches pass -cpuClock as an argument, which must not count.)
        let saved = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        if saved["cpuClockAuto"] == nil, let manual = saved["cpuClock"] as? Int, manual != 100 {
            cpuClockAuto = false
        }
        // 0.55 was the old default; with the lighter keys it is too faint. Move it up once.
        if !d.bool(forKey: "controllerOpacityMigrated") {
            if d.object(forKey: "controllerOpacity") != nil, abs(controllerOpacity - 0.55) < 0.001 { controllerOpacity = 0.75 }
            d.set(true, forKey: "controllerOpacityMigrated")
        }
        if nickname.isEmpty {
            nickname = "iOS-" + String(UUID().uuidString.prefix(4))
        }
        if lobbyToken.isEmpty {
            // Open lobbies accept any non-empty token; a random one identifies this device.
            lobbyToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    }

    /// Writes the emulator part of the settings for the core.
    func writeCoreConfig(to userDirectory: URL) {
        #if APPSTORE
        let allowJIT = false
        #else
        let allowJIT = true
        #endif
        let ini = """
        ; Written by the 3DS_iOS app. Edit settings in the app instead of here.
        [Core]
        use_cpu_jit = \(allowJIT)
        cpu_clock_percentage = \(effectiveCPUClock)

        [Renderer]
        graphics_api = 2
        use_hw_shader = true
        shaders_accurate_mul = \(accurateMul)
        use_disk_shader_cache = \(diskShaderCache)
        async_shader_compilation = \(asyncShaders)
        async_presentation = true
        spirv_shader_gen = true
        resolution_factor = \(resolutionFactor)
        frame_limit = \(frameLimit)
        use_vsync = \(vsync)
        texture_filter = \(textureFilter)
        filter_mode = \(linearFiltering)

        [Layout]
        layout_option = \(landscapeLayout.coreValue)
        portrait_layout_option = 0
        swap_screen = \(swapScreens)

        [Audio]
        audio_emulation = \(lleAudio ? 1 : 0)
        enable_audio_stretching = \(audioStretching)
        volume = \(volume)
        output_type = 0
        input_type = 1

        [System]
        is_new_3ds = \(isNew3DS)
        lle_applets = \(lleApplets)
        region_value = \(region)

        [Data Storage]
        use_virtual_sd = true

        [WebService]
        web_api_url = \(lobbyURL)
        network_token = \(lobbyToken)

        [Miscellaneous]
        log_filter = *:Info

        """
        let url = userDirectory.appendingPathComponent("config/ios-config.ini")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ini.write(to: url, atomically: true, encoding: .utf8)
    }
}
