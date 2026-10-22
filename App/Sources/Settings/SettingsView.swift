import AzaharCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var core = EmulatorCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var showSysdataImporter = false
    @State private var message: String?

    var body: some View {
        Form {
            jitSection

            Section("画面") {
                Picker("内部分辨率", selection: $s.resolutionFactor) {
                    ForEach(1...6, id: \.self) { Text("\($0)× (\(400 * $0)×\(240 * $0))").tag($0) }
                }
                Toggle("异步着色器编译（减少卡顿）", isOn: $s.asyncShaders)
                Toggle("磁盘着色器缓存", isOn: $s.diskShaderCache)
                Toggle("垂直同步", isOn: $s.vsync)
                Toggle("线性过滤", isOn: $s.linearFiltering)
                Picker("纹理滤镜", selection: $s.textureFilter) {
                    Text("无").tag(0); Text("Anime4K").tag(1); Text("Bicubic").tag(2)
                    Text("ScaleForce").tag(3); Text("xBRZ").tag(4); Text("MMPX").tag(5)
                }
                Toggle("精确着色器乘法", isOn: $s.accurateMul)
                Picker("横屏布局", selection: Binding(get: { s.landscapeLayout }, set: { s.landscapeLayout = $0 })) {
                    ForEach(AppSettings.ScreenLayout.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("性能") {
                Stepper("CPU 频率 \(s.cpuClock)%", value: $s.cpuClock, in: 25...400, step: 25)
                Stepper("帧率上限 \(s.frameLimit)%", value: $s.frameLimit, in: 25...400, step: 25)
                Stepper("快进速度 \(s.fastForwardSpeed)%", value: $s.fastForwardSpeed, in: 150...1000, step: 50)
            }

            Section("声音") {
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $s.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                }
                Toggle("音频拉伸（掉帧时不爆音）", isOn: $s.audioStretching)
                Toggle("LLE 音频（更准确，更慢）", isOn: $s.lleAudio)
            }

            Section("控制") {
                HStack {
                    Text("虚拟按键透明度")
                    Slider(value: $s.controllerOpacity, in: 0.15...1)
                }
                Toggle("触感反馈", isOn: $s.haptics)
                Toggle("体感（陀螺仪）", isOn: $s.motionControls)
                Toggle("连接手柄时隐藏虚拟按键", isOn: $s.hideControllerWithGamepad)
            }

            Section {
                Toggle("New 3DS 模式", isOn: $s.isNew3DS)
                Picker("地区", selection: $s.region) {
                    Text("自动").tag(-1); Text("日本").tag(0); Text("北美").tag(1); Text("欧洲").tag(2)
                    Text("澳洲").tag(3); Text("中国").tag(4); Text("韩国").tag(5); Text("台湾").tag(6)
                }
                Toggle("LLE 小程序（需系统文件）", isOn: $s.lleApplets)
                HStack {
                    TextField("主机昵称", text: $username)
                    Button("保存") {
                        az_set_console_username(username)
                        message = "已保存主机昵称"
                    }
                    .disabled(username.isEmpty || az_is_running())
                }
                Button("导入系统文件 / 密钥…") { showSysdataImporter = true }
                Toggle("安装 CIA 后删除原文件", isOn: $s.deleteCIAAfterInstall)
            } header: {
                Text("系统")
            } footer: {
                Text("部分游戏需要系统文件（如 aes_keys.txt、shared fonts、系统存档）。只能导入从你自己的 3DS 导出的文件，会放进 Bifold › Azahar › sysdata。\n放进 Bifold 文件夹的 .cia（游戏本体、更新、DLC）会自动安装；默认保留原文件到 Games › 已安装的 CIA，打开上面的开关则安装后直接删除，节省空间。")
            }

            Section {
                LabeledContent("联机昵称") {
                    TextField("4–20 个字符", text: $s.nickname).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField("大厅服务器（如 http://lobby.example.com:5000）", text: $s.lobbyURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("大厅令牌") {
                    TextField("令牌", text: $s.lobbyToken).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
                }
                Toggle("局域网自动发现", isOn: $s.lanDiscovery)
            } header: {
                Text("联机")
            } footer: {
                Text("大厅服务器用于列出公开房间，见 Server/README.md 自建。Azahar 的大厅协议只支持 http://。开放大厅接受任意令牌；封闭大厅需要管理员分配的令牌。")
            }

            Section("关于") {
                LabeledContent("模拟核心", value: core.coreVersion)
                LabeledContent("JIT", value: JITHelper.statusText)
                Link("源代码（GPL-2.0）", destination: URL(string: "https://github.com/azahar-emu/azahar")!)
                Text("本应用基于 Azahar 模拟器（Citra 的后继项目），以 GPL-2.0 或更新版本授权。不包含任何游戏、BIOS 或密钥。请只运行你合法拥有的游戏。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear {
            if let p = az_get_console_username() { username = String(cString: p); az_free(p) }
        }
        .onDisappear { core.reloadSettings() }
        .fileImporter(isPresented: $showSysdataImporter, allowedContentTypes: [.data, .text], allowsMultipleSelection: true) { result in
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
            message = "已导入 \(copied) 个文件到 sysdata"
        }
        .alert("设置", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    @ViewBuilder private var jitSection: some View {
        #if APPSTORE
        Section {
            Label("App Store 版本使用解释器运行，3D 游戏可能达不到全速。", systemImage: "info.circle")
        }
        #else
        Section {
            Label(JITHelper.statusText, systemImage: JITHelper.isEnabled ? "bolt.fill" : "tortoise.fill")
                .foregroundStyle(JITHelper.isEnabled ? .green : .orange)
            if !JITHelper.isEnabled {
                Button("用 StikDebug 开启 JIT") { JITHelper.requestViaStikDebug() }
            }
            Picker("JIT 内存模式", selection: Binding(get: { s.jitMode }, set: { s.jitMode = $0 })) {
                ForEach(AppSettings.JITMode.allCases) { Text($0.title).tag($0) }
            }
            Stepper("JIT 内存池 \(s.jitArenaMB) MB", value: $s.jitArenaMB, in: 64...1024, step: 64)
                .disabled(s.jitMode == .legacy)
        } header: {
            Text("JIT")
        } footer: {
            Text("JIT 让 3DS 的 ARM 代码以接近原生的速度运行。需要侧载安装（开发证书签名）并用 StikDebug 等工具开启；iOS 26 的 A15 及更新设备需要 StikDebug 的通用脚本（universal.js）。JIT 模式和内存池在重启应用后生效。")
        }
        #endif
    }
}
