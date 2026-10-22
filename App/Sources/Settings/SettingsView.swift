import AzaharCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings home: emulator status first, then one row per area.
struct SettingsView: View {
    var isTab = false
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var core = EmulatorCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section { statusCard }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)

            Section {
                row("画面", "rectangle.on.rectangle", 0x4F7DD6, "\(s.resolutionFactor)×") { GraphicsSettings() }
                row("性能", "bolt.fill", 0xD8862F, "快进 \(s.fastForwardSpeed)%") { PerformanceSettings() }
                row("声音", "speaker.wave.2.fill", 0x3FA37A, "\(Int(s.volume * 100))%") { AudioSettings() }
                row("按键与手柄", "gamecontroller.fill", 0x8C64D8, nil) { ControlSettings() }
            }
            Section {
                row("主机与系统文件", "cpu", 0x5B6B82, s.isNew3DS ? "New 3DS" : "3DS") { SystemSettings() }
                row("联机", "person.2.wave.2.fill", 0x2E9BC2, s.nickname) { MultiplayerSettings() }
                row("导入与安装", "tray.and.arrow.down.fill", 0x6E7787, s.deleteCIAAfterInstall ? "删除原 CIA" : "保留原 CIA") { ImportSettings() }
            }
            Section {
                row("关于 Bifold", "info.circle.fill", 0x3A4556, nil) { AboutView() }
            }
        }
        .themedList()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(isTab ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if !isTab { Button("完成") { dismiss() } }
            }
        }
        .onDisappear { core.reloadSettings() }
    }

    private func row<D: View>(_ title: String, _ icon: String, _ color: UInt32, _ value: String?,
                              @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination().onDisappear { core.reloadSettings() }
        } label: {
            HStack(spacing: 12) {
                IconTile(systemName: icon, color: Color(UIColor(hex: color)))
                Text(title).font(.body.weight(.semibold))
                Spacer()
                if let value { Text(value).foregroundStyle(Theme.secondaryText).lineLimit(1) }
            }
        }
        .listRowBackground(Theme.surface)
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: JITHelper.isEnabled ? "bolt.fill" : "tortoise.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(JITHelper.isEnabled ? Theme.led : .orange)
                .frame(width: 48, height: 48)
                .background((JITHelper.isEnabled ? Theme.led : Color.orange).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(JITHelper.isEnabled ? "JIT 已启用" : "JIT 未启用").font(.system(size: 17, weight: .bold, design: .rounded))
                Text(JITHelper.isEnabled ? JITHelper.statusText : "游戏会用解释器运行，3D 游戏可能达不到全速")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            #if !APPSTORE
            if !JITHelper.isEnabled {
                Button("开启") { JITHelper.requestViaStikDebug() }
                    .font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
            } else {
                StatusLight()
            }
            #endif
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Pages

private struct GraphicsSettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ThemedForm {
            Section {
                Picker("内部分辨率", selection: $s.resolutionFactor) {
                    ForEach(1...6, id: \.self) { Text("\($0)×（\(400 * $0)×\(240 * $0)）").tag($0) }
                }
                Picker("横屏布局", selection: Binding(get: { s.landscapeLayout }, set: { s.landscapeLayout = $0 })) {
                    ForEach(AppSettings.ScreenLayout.allCases) { Text($0.title).tag($0) }
                }
            } footer: { Text("分辨率越高画面越清晰，也越耗电、越热。2× 是大多数手机的平衡点。") }
            Section {
                Toggle("线性过滤", isOn: $s.linearFiltering)
                Picker("纹理滤镜", selection: $s.textureFilter) {
                    Text("无").tag(0); Text("Anime4K").tag(1); Text("Bicubic").tag(2)
                    Text("ScaleForce").tag(3); Text("xBRZ").tag(4); Text("MMPX").tag(5)
                }
                Toggle("垂直同步", isOn: $s.vsync)
            }
            Section {
                Toggle("异步编译着色器", isOn: $s.asyncShaders)
                Toggle("磁盘着色器缓存", isOn: $s.diskShaderCache)
                Toggle("精确着色器乘法", isOn: $s.accurateMul)
            } footer: { Text("异步编译能减少新场景第一次出现时的卡顿；磁盘缓存让下次启动更快。") }
        }
        .tint(Theme.accent).themedList().navigationTitle("画面")
    }
}

private struct PerformanceSettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ThemedForm {
            #if !APPSTORE
            Section {
                Picker("JIT 内存模式", selection: Binding(get: { s.jitMode }, set: { s.jitMode = $0 })) {
                    ForEach(AppSettings.JITMode.allCases) { Text($0.title).tag($0) }
                }
                Stepper("JIT 内存池 \(s.jitArenaMB) MB", value: $s.jitArenaMB, in: 64...1024, step: 64)
                    .disabled(s.jitMode == .legacy)
            } header: { Text("JIT") } footer: {
                Text("JIT 让 3DS 的程序以接近原生的速度运行，需要侧载安装并用 StikDebug 等工具开启；iOS 26 的 A15 及更新设备需要 StikDebug 的通用脚本。大型游戏（如宝可梦）至少需要 256 MB 内存池。重启 App 后生效。")
            }
            #endif
            Section {
                Stepper("快进速度 \(s.fastForwardSpeed)%", value: $s.fastForwardSpeed, in: 150...1000, step: 50)
                Stepper("帧率上限 \(s.frameLimit)%", value: $s.frameLimit, in: 25...400, step: 25)
                Stepper("CPU 频率 \(s.cpuClock)%", value: $s.cpuClock, in: 25...400, step: 25)
            } footer: { Text("CPU 频率高于 100% 可让个别掉帧的游戏更流畅，但也可能让游戏出错。") }
        }
        .tint(Theme.accent).themedList().navigationTitle("性能")
    }
}

private struct AudioSettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ThemedForm {
            Section {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(Theme.secondaryText)
                    Slider(value: $s.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.secondaryText)
                }
            }
            Section {
                Toggle("音频拉伸", isOn: $s.audioStretching)
                Toggle("LLE 音频", isOn: $s.lleAudio)
            } footer: { Text("音频拉伸让掉帧时不爆音。LLE 音频更准确，但明显更慢。") }
        }
        .tint(Theme.accent).themedList().navigationTitle("声音")
    }
}

private struct ControlSettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ThemedForm {
            Section {
                VStack(alignment: .leading) {
                    Text("虚拟按键透明度")
                    Slider(value: $s.controllerOpacity, in: 0.15...1)
                }
                Toggle("触感反馈", isOn: $s.haptics)
            }
            Section {
                Toggle("体感（陀螺仪）", isOn: $s.motionControls)
                Toggle("连接手柄时隐藏虚拟按键", isOn: $s.hideControllerWithGamepad)
            } footer: { Text("支持 MFi、Xbox、PlayStation 等蓝牙手柄。") }
        }
        .tint(Theme.accent).themedList().navigationTitle("按键与手柄")
    }
}

private struct SystemSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var core = EmulatorCore.shared
    @State private var username = ""
    @State private var showImporter = false
    @State private var message: String?

    var body: some View {
        ThemedForm {
            Section {
                Toggle("New 3DS 模式", isOn: $s.isNew3DS)
                Picker("地区", selection: $s.region) {
                    Text("自动").tag(-1); Text("日本").tag(0); Text("北美").tag(1); Text("欧洲").tag(2)
                    Text("澳洲").tag(3); Text("中国").tag(4); Text("韩国").tag(5); Text("台湾").tag(6)
                }
                HStack {
                    TextField("主机昵称", text: $username)
                    Button("保存") {
                        az_set_console_username(username)
                        message = "已保存主机昵称"
                    }
                    .disabled(username.isEmpty || az_is_running())
                }
            }
            Section {
                NavigationLink { KeysHelpView() } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("密钥")
                        Text(KeysHelp.text.short).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                }
                Button("导入系统文件或密钥…") { showImporter = true }
                Toggle("LLE 小程序（需系统文件）", isOn: $s.lleApplets)
            } header: { Text("系统文件") } footer: {
                Text("只能导入从你自己的 3DS 导出的文件，例如 aes_keys.txt、seeddb.bin、共享字体。它们会放进 Bifold › Azahar › sysdata。")
            }
        }
        .tint(Theme.accent).themedList().navigationTitle("主机与系统文件")
        .onAppear { if let p = az_get_console_username() { username = String(cString: p); az_free(p) } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .text], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let dest = core.userDirectory.appendingPathComponent("sysdata", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            var copied = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let target = dest.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.copyItem(at: url, to: target)) != nil { copied += 1 }
            }
            message = "已导入 \(copied) 个文件到 sysdata。重启游戏后生效。"
        }
        .alert("系统文件", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}

private struct MultiplayerSettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ThemedForm {
            Section {
                LabeledContent("昵称") {
                    TextField("4–20 个字符", text: $s.nickname).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("局域网自动发现", isOn: $s.lanDiscovery)
            }
            Section {
                TextField("http://lobby.example.com:5000", text: $s.lobbyURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("令牌") {
                    TextField("令牌", text: $s.lobbyToken).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
                }
            } header: { Text("大厅服务器") } footer: {
                Text("大厅用来列出公开房间，可以按 Server/README.md 自建。Azahar 的大厅协议只支持 http://。开放大厅接受任意令牌；封闭大厅要用管理员分配的令牌。")
            }
        }
        .tint(Theme.accent).themedList().navigationTitle("联机")
    }
}

private struct ImportSettings: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ThemedForm {
            Section {
                Toggle("安装 CIA 后删除原文件", isOn: $s.deleteCIAAfterInstall)
            } footer: {
                Text("放进 Bifold 文件夹的 .cia（游戏本体、更新、DLC）会自动安装。默认把原文件留在 Games › 已安装的 CIA；打开开关则安装后直接删除，节省空间。加密的 CIA 无法安装。")
            }
        }
        .tint(Theme.accent).themedList().navigationTitle("导入与安装")
    }
}

private struct AboutView: View {
    @ObservedObject private var core = EmulatorCore.shared
    var body: some View {
        ThemedForm {
            Section {
                LabeledContent("模拟核心", value: core.coreVersion)
                LabeledContent("JIT", value: JITHelper.statusText)
            }
            Section {
                Link("Bifold 源代码", destination: URL(string: "https://github.com/Bifold-Emu/Bifold")!)
                Link("Azahar 项目", destination: URL(string: "https://github.com/azahar-emu/azahar")!)
            } footer: {
                Text("Bifold 基于 Azahar 模拟器（Citra 的后继项目），以 GNU GPL 授权，源代码公开。Bifold 不包含任何游戏、系统固件或密钥。请只运行你合法拥有的游戏。Nintendo 3DS 是任天堂的商标；Bifold 与任天堂没有任何关系。")
            }
        }
        .tint(Theme.accent).themedList().navigationTitle("关于 Bifold")
    }
}

// MARK: - Keys help

/// Why Bifold ships no keys and how players can add their own: a short version and a detailed
/// one, in the player's language (Simplified/Traditional Chinese, Japanese, English).
enum KeysHelp {
    struct Content { let title, short, detailTitle: String; let details: [(String, String)]; let link: String }

    static var text: Content {
        let lang = Locale.preferredLanguages.first ?? "en"
        if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") { return zhHant }
        if lang.hasPrefix("zh") { return zhHans }
        if lang.hasPrefix("ja") { return ja }
        return en
    }

    static let zhHans = Content(
        title: "密钥",
        short: "Bifold 不内置任何任天堂密钥。大多数已解密的游戏不需要密钥。需要时，可以从你自己的 3DS 导出 aes_keys.txt 再导入。",
        detailTitle: "详细说明",
        details: [
            ("什么时候需要", "本地无线联机时和带密钥的设备（如电脑上的 Azahar）互通、amiibo、下载游玩、Mii 二维码，以及部分游戏的网络功能。两台都没有密钥的 Bifold 之间仍然可以联机。"),
            ("什么时候没用", "加密的游戏和 CIA：无论有没有密钥，Azahar 都不支持，请使用解密后的文件。"),
            ("怎么导出", "在你自己的、已安装自制系统的 3DS 上，把 DumpKeys 脚本放进 SD 卡的 gm9/scripts，打开 GodMode9 → HOME → Scripts → DumpKeys。完成后 SD 卡的 gm9 文件夹里会有 aes_keys.txt（可能还有 seeddb.bin）。"),
            ("怎么导入", "设置 › 主机与系统文件 › 导入系统文件或密钥，选择 aes_keys.txt；或者用「文件」App / 电脑把它放进 Bifold › Azahar › sysdata。重新打开游戏后生效。"),
            ("为什么不内置", "密钥属于任天堂。Bifold 只提供模拟器本身，导入密钥由你自己决定，也只能用你自己主机上的。"),
        ],
        link: "导出步骤（Citra 维基）")

    static let zhHant = Content(
        title: "金鑰",
        short: "Bifold 不內建任何任天堂金鑰。大多數已解密的遊戲不需要金鑰。需要時，可以從你自己的 3DS 匯出 aes_keys.txt 再匯入。",
        detailTitle: "詳細說明",
        details: [
            ("什麼時候需要", "本地無線連線時和帶金鑰的裝置（如電腦上的 Azahar）互通、amiibo、下載遊玩、Mii QR 碼，以及部分遊戲的網路功能。兩台都沒有金鑰的 Bifold 之間仍然可以連線。"),
            ("什麼時候沒用", "加密的遊戲和 CIA：無論有沒有金鑰，Azahar 都不支援，請使用解密後的檔案。"),
            ("怎麼匯出", "在你自己的、已安裝自製系統的 3DS 上，把 DumpKeys 腳本放進 SD 卡的 gm9/scripts，開啟 GodMode9 → HOME → Scripts → DumpKeys。完成後 SD 卡的 gm9 資料夾裡會有 aes_keys.txt（可能還有 seeddb.bin）。"),
            ("怎麼匯入", "設定 › 主機與系統檔案 › 匯入系統檔案或金鑰，選擇 aes_keys.txt；或者用「檔案」App／電腦把它放進 Bifold › Azahar › sysdata。重新開啟遊戲後生效。"),
            ("為什麼不內建", "金鑰屬於任天堂。Bifold 只提供模擬器本身，匯入金鑰由你自己決定，也只能用你自己主機上的。"),
        ],
        link: "匯出步驟（Citra Wiki）")

    static let ja = Content(
        title: "暗号鍵",
        short: "Bifold には任天堂の暗号鍵は含まれていません。復号済みのゲームのほとんどは鍵なしで動きます。必要なときは、自分の 3DS から aes_keys.txt を取り出して読み込めます。",
        detailTitle: "詳しい説明",
        details: [
            ("必要な場面", "鍵を持つ端末（PC 版 Azahar など）とのローカル通信、amiibo、ダウンロードプレイ、Mii の QR コード、一部ゲームのネットワーク機能。鍵のない Bifold 同士なら通信できます。"),
            ("役に立たない場面", "暗号化されたゲームと CIA は、鍵があっても Azahar では使えません。復号済みのファイルを使ってください。"),
            ("取り出し方", "自作ファームを導入した自分の 3DS で、DumpKeys スクリプトを SD カードの gm9/scripts に置き、GodMode9 → HOME → Scripts → DumpKeys を実行します。SD カードの gm9 フォルダに aes_keys.txt（と seeddb.bin）ができます。"),
            ("読み込み方", "設定 › 本体とシステムファイル › システムファイルの読み込み で aes_keys.txt を選ぶか、「ファイル」App や PC で Bifold › Azahar › sysdata に置きます。ゲームを開き直すと有効になります。"),
            ("内蔵しない理由", "鍵は任天堂のものです。Bifold はエミュレーターだけを提供し、鍵を読み込むかどうかはあなたが決めます。使えるのは自分の本体の鍵だけです。"),
        ],
        link: "取り出し手順（Citra Wiki）")

    static let en = Content(
        title: "Keys",
        short: "Bifold includes no Nintendo keys. Most decrypted games run without them. If you need keys, dump aes_keys.txt from your own 3DS and import it.",
        detailTitle: "Details",
        details: [
            ("When you need them", "Local wireless play with devices that have keys (such as Azahar on a computer), amiibo, Download Play, Mii QR codes, and some games' online features. Two Bifold devices without keys can still play together."),
            ("When they don't help", "Encrypted games and CIAs: Azahar doesn't support them with or without keys. Use decrypted files."),
            ("How to dump them", "On your own 3DS with custom firmware, put the DumpKeys script in gm9/scripts on the SD card, then open GodMode9 → HOME → Scripts → DumpKeys. The SD card's gm9 folder then has aes_keys.txt (and possibly seeddb.bin)."),
            ("How to import them", "Settings › Console and system files › Import system files or keys and pick aes_keys.txt, or copy it into Bifold › Azahar › sysdata with the Files app or a computer. Reopen the game to use it."),
            ("Why they aren't built in", "The keys belong to Nintendo. Bifold provides only the emulator; importing keys is your choice, and only keys from your own console."),
        ],
        link: "Dumping steps (Citra wiki)")
}

struct KeysHelpView: View {
    @State private var expanded = false
    private let t = KeysHelp.text

    var body: some View {
        List {
            Section {
                Text(t.short).font(.body).padding(.vertical, 4)
                DisclosureGroup(t.detailTitle, isExpanded: $expanded) {
                    ForEach(t.details, id: \.0) { title, body in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.subheadline.weight(.bold))
                            Text(body).font(.subheadline).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.vertical, 4)
                    }
                    Link(t.link, destination: URL(string: "https://git.openpunk.com/OpenPunk/citra/wiki/AES-Keys")!)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .listRowBackground(Theme.surface)
        }
        .tint(Theme.accent).themedList().navigationTitle(t.title)
    }
}
