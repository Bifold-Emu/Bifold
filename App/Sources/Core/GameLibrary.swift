import AzaharCore
import Foundation
import UIKit
import UniformTypeIdentifiers

struct Game: Identifiable, Hashable {
    let url: URL
    let title: String
    let publisher: String
    let titleID: UInt64
    let fileType: String
    let encrypted: Bool
    let icon: UIImage?
    let isInstalledTitle: Bool
    /// Installed update (0004000E…) for this game, applied automatically when it boots.
    var updateVersion: UInt16?
    /// Installed add-on content (0004008C…) for this game.
    var hasDLC = false

    var id: String { url.path }
    var titleIDString: String { String(format: "%016llX", titleID) }
    /// Low 32 bits of the title ID: shared by a game, its update and its DLC.
    var uniqueID: UInt32 { UInt32(truncatingIfNeeded: titleID) }

    static func == (a: Game, b: Game) -> Bool { a.url == b.url && a.updateVersion == b.updateVersion && a.hasDLC == b.hasDLC }
    func hash(into h: inout Hasher) { h.combine(url) }

    /// The raw title version (as 3DS tools show it, e.g. "v2112"). Games do not map it to their
    /// marketing version consistently — Pokémon Sun's "1.2" update is v2112 — so no decoding.
    static func versionString(_ v: UInt16) -> String { "v\(v)" }
}

/// Keeps the list of games in <Documents>/Games plus titles installed from CIA files, and
/// imports whatever the user drops into the app's folder (Files app, Finder on a Mac, or
/// iTunes / Apple Devices on Windows):
///   • game files (.3ds/.cci/.cxi/.3dsx…) in the folder root are moved into Games/
///   • .cia/.zcia files in the root or anywhere under Games/ are installed into the emulated
///     SD card, then moved to Games/已安装的 CIA (or deleted, see AppSettings) — failures go to
///     Games/安装失败 so they are not retried in a loop.
@MainActor
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published private(set) var games: [Game] = []
    @Published private(set) var isScanning = false
    /// Non-blocking banner about finished imports (an alert here would race with opening a game).
    @Published private(set) var notice: String?
    private var noticeTimer: DispatchWorkItem?
    /// CIAs installed through the file picker, reported after the next scan so that an update
    /// can be described with its game's name even when both were installed together.
    private var pickerInstalled: [InstalledCIA] = []
    @Published var installProgress: Double?
    @Published private(set) var installingName: String?

    static let romExtensions: Set<String> = ["3ds", "cci", "cxi", "3dsx", "app", "elf", "axf", "zcci", "zcxi", "z3dsx"]
    static let ciaExtensions: Set<String> = ["cia", "zcia"]
    static let installedFolderName = "已安装的 CIA"
    static let failedFolderName = "安装失败"
    static let importTypes: [UTType] = {
        var types: [UTType] = [.data]
        for ext in ["3ds", "cci", "cxi", "cia", "3dsx", "app", "elf", "zcci", "zcxi", "z3dsx", "zcia"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    nonisolated static var gamesDirectory: URL {
        documentsDirectory.appendingPathComponent("Games", isDirectory: true)
    }
    var gamesDirectory: URL { Self.gamesDirectory }

    private var rescanRequested = false
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var debounce: DispatchWorkItem?

    private init() {
        try? FileManager.default.createDirectory(at: Self.gamesDirectory, withIntermediateDirectories: true)
        watch(Self.documentsDirectory)
        watch(Self.gamesDirectory)
    }

    /// Re-scans when something is added to the folder while the app is open (e.g. a Finder copy).
    private func watch(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh(after: 1) }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }

    func scheduleRefresh(after seconds: Double) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func refresh() {
        guard !isScanning else { rescanRequested = true; return }
        isScanning = true
        rescanRequested = false
        // Never install while a game runs: the core would write the SD card it is reading from.
        let canInstall = !az_is_running()
        let deleteAfterInstall = AppSettings.shared.deleteCIAAfterInstall
        let known = Dictionary(games.map { ($0.uniqueID, $0.title) }, uniquingKeysWith: { a, _ in a })
        Task.detached(priority: .userInitiated) {
            let report = await GameLibrary.autoImport(canInstall: canInstall, deleteAfterInstall: deleteAfterInstall,
                                                      knownTitles: known)
            var found: [Game] = []
            let fm = FileManager.default
            let skip: Set<String> = [GameLibrary.installedFolderName, GameLibrary.failedFolderName]
            if let e = fm.enumerator(at: GameLibrary.gamesDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let url as URL in e {
                    if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                    guard GameLibrary.romExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    if let g = GameLibrary.loadInfo(url, installed: false) { found.append(g) }
                }
            }
            // Titles installed into the emulated SD card from .cia files (applications only;
            // updates and DLC are attached to their game below).
            if let p = az_list_installed_titles() {
                let json = String(cString: p)
                az_free(p)
                struct Installed: Decodable { let path: String; let title_id: UInt64 }
                let installed = (try? JSONDecoder().decode([Installed].self, from: Data(json.utf8))) ?? []
                for t in installed {
                    if let g = GameLibrary.loadInfo(URL(fileURLWithPath: t.path), installed: true) { found.append(g) }
                }
            }
            var titleNames: [UInt32: String] = known
            for g in found where g.titleID != 0 { titleNames[g.uniqueID] = g.title }
            let names = titleNames
            let messages = report.installed.map {
                GameLibrary.describeInstalled(name: $0.name, info: $0.info, knownTitles: names)
            } + report.failures
            let addons = GameLibrary.installedAddons()
            for i in found.indices {
                if let a = addons[found[i].uniqueID] {
                    found[i].updateVersion = a.update
                    found[i].hasDLC = a.dlc
                }
            }
            found.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let result = found
            await MainActor.run {
                self.games = result
                self.isScanning = false
                self.installProgress = nil
                self.installingName = nil
                let picked = self.pickerInstalled.map { GameLibrary.describeInstalled(name: $0.name, info: $0.info, knownTitles: names) }
                self.pickerInstalled.removeAll()
                let all = picked + messages
                if !all.isEmpty { self.post(all.joined(separator: "\n")) }
                if self.rescanRequested {
                    self.refresh()
                } else if report.pending {
                    self.scheduleRefresh(after: 3)
                }
            }
        }
    }

    // MARK: Updates / DLC

    nonisolated static func installedAddons() -> [UInt32: (update: UInt16?, dlc: Bool)] {
        guard let p = az_list_installed_addons() else { return [:] }
        let json = String(cString: p)
        az_free(p)
        struct Addon: Decodable { let title_id: UInt64; let kind: String; let version: UInt16 }
        let list = (try? JSONDecoder().decode([Addon].self, from: Data(json.utf8))) ?? []
        var result: [UInt32: (update: UInt16?, dlc: Bool)] = [:]
        for a in list {
            let key = UInt32(truncatingIfNeeded: a.title_id)
            var entry = result[key] ?? (update: nil, dlc: false)
            if a.kind == "update" { entry.update = a.version } else { entry.dlc = true }
            result[key] = entry
        }
        return result
    }

    // MARK: Folder import

    struct InstalledCIA { let name: String; let info: AZCIAInfo? }
    struct ImportReport { var installed: [InstalledCIA] = []; var failures: [String] = []; var pending = false }

    /// Shows a banner for a few seconds; a new message while one is visible is appended.
    func post(_ text: String) {
        var lines = (notice.map { $0.components(separatedBy: "\n") } ?? []) + text.components(separatedBy: "\n")
        if lines.count > 5 { lines = Array(lines.suffix(5)) }
        notice = lines.joined(separator: "\n")
        noticeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func dismissNotice() {
        noticeTimer?.cancel()
        notice = nil
    }

    /// A file that changed in the last few seconds may still be arriving (Finder / iTunes /
    /// devicectl copies write it progressively), so it is left for the next scan.
    /// The status-change time (ctime) is used, not the modification date: copy tools set the
    /// modification date to the source file's, and some create the file at its final size first,
    /// so neither the date nor the size shows a copy in progress. ctime cannot be set from outside
    /// and moves on every write.
    nonisolated static func isStillArriving(_ url: URL) -> Bool {
        guard let first = fileState(url) else { return true }
        if Date().timeIntervalSince1970 - first.ctime < 5 { return true }
        Thread.sleep(forTimeInterval: 1)
        guard let again = fileState(url) else { return true }
        return again != first
    }

    struct FileState: Equatable { let size: Int64; let ctime: Double }

    nonisolated static func fileState(_ url: URL) -> FileState? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let ctime = Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1e9
        return FileState(size: Int64(st.st_size), ctime: ctime)
    }

    /// Moves `url` into `dir`, adding " (2)", " (3)"… instead of overwriting.
    @discardableResult
    nonisolated static func move(_ url: URL, into dir: URL) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        do { try fm.moveItem(at: url, to: dest); return dest } catch { return nil }
    }

    nonisolated static func autoImport(canInstall: Bool, deleteAfterInstall: Bool,
                                       knownTitles: [UInt32: String]) async -> ImportReport {
        var report = ImportReport()
        let fm = FileManager.default
        let docs = documentsDirectory
        let games = gamesDirectory
        var cias: [URL] = []

        // 1. Folder root: game files go into Games/, CIAs are collected.
        let rootItems = (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        for url in rootItems where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let ext = url.pathExtension.lowercased()
            if ciaExtensions.contains(ext) {
                cias.append(url)
            } else if romExtensions.contains(ext) {
                if isStillArriving(url) { report.pending = true; continue }
                move(url, into: games)
            }
        }
        // 2. CIAs anywhere under Games/ except the two result folders.
        let skip: Set<String> = [installedFolderName, failedFolderName]
        if let e = fm.enumerator(at: games, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                if ciaExtensions.contains(url.pathExtension.lowercased()) { cias.append(url) }
            }
        }
        // 3. Install, one at a time.
        for url in cias {
            if isStillArriving(url) { report.pending = true; continue }
            guard canInstall else { report.pending = true; continue }
            var info = AZCIAInfo()
            let hasInfo = az_get_cia_info(url.path, &info)
            let name = url.lastPathComponent
            await MainActor.run {
                GameLibrary.shared.installingName = name
                GameLibrary.shared.installProgress = 0
            }
            let before = fileState(url)
            let code = await installCIAFile(url.path)
            if let after = fileState(url), let before,
               after != before || Date().timeIntervalSince1970 - after.ctime < 5 {
                // Written to while we read it: an unfinished copy, not a bad file (and a "success"
                // would have installed half a file). Install it again once the copy is done.
                report.pending = true
                continue
            }
            if code == 0 {
                if deleteAfterInstall {
                    try? fm.removeItem(at: url)
                } else {
                    move(url, into: games.appendingPathComponent(installedFolderName, isDirectory: true))
                }
                report.installed.append(InstalledCIA(name: name, info: hasInfo ? info : nil))
            } else {
                move(url, into: games.appendingPathComponent(failedFolderName, isDirectory: true))
                report.failures.append("安装失败 \(name)：\(ciaError(code))（已移到 Games › \(failedFolderName)）")
            }
        }
        return report
    }

    nonisolated static func describeInstalled(name: String, info: AZCIAInfo?, knownTitles: [UInt32: String]) -> String {
        guard var info else { return "已安装 \(name)" }
        let ciaTitle = withUnsafeBytes(of: &info.title) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let game = knownTitles[UInt32(truncatingIfNeeded: info.title_id)] ?? (ciaTitle.isEmpty ? nil : ciaTitle)
        let suffix = game.map { "：\($0)" } ?? "（\(name)）"
        switch info.kind {
        case AZ_TITLE_UPDATE: return "已安装更新 \(Game.versionString(info.version))\(suffix)"
        case AZ_TITLE_DLC: return "已安装 DLC\(suffix)"
        case AZ_TITLE_APPLICATION: return "已安装 \(game ?? name)"
        default: return "已安装 \(name)（系统数据）"
        }
    }

    nonisolated static func installCIAFile(_ path: String) async -> Int32 {
        await Task.detached {
            az_install_cia(path, { done, total, _ in
                let p = total > 0 ? Double(done) / Double(total) : 0
                Task { @MainActor in GameLibrary.shared.installProgress = p }
            }, nil)
        }.value
    }

    nonisolated static func loadInfo(_ url: URL, installed: Bool) -> Game? {
        var info = AZGameInfo()
        let language = preferredSMDHLanguage()
        guard az_get_game_info(url.path, language, &info) else { return nil }
        let title = withUnsafeBytes(of: &info.title) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let publisher = withUnsafeBytes(of: &info.publisher) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let type = withUnsafeBytes(of: &info.file_type) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        var icon: UIImage?
        if info.has_icon {
            icon = withUnsafeBytes(of: &info.icon_rgba) { raw -> UIImage? in
                guard let provider = CGDataProvider(data: Data(raw) as CFData),
                      let cg = CGImage(width: 48, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: true,
                                       intent: .defaultIntent) else { return nil }
                return UIImage(cgImage: cg)
            }
        }
        return Game(url: url, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                    publisher: publisher, titleID: info.title_id, fileType: type,
                    encrypted: info.encrypted, icon: icon, isInstalledTitle: installed)
    }

    nonisolated static func preferredSMDHLanguage() -> Int32 {
        let lang = Locale.preferredLanguages.first ?? "en"
        if lang.hasPrefix("zh-Hans") || lang.hasPrefix("zh-CN") { return 6 }
        if lang.hasPrefix("zh") { return 11 }
        if lang.hasPrefix("ja") { return 0 }
        if lang.hasPrefix("ko") { return 7 }
        if lang.hasPrefix("fr") { return 2 }
        if lang.hasPrefix("de") { return 3 }
        if lang.hasPrefix("it") { return 4 }
        if lang.hasPrefix("es") { return 5 }
        if lang.hasPrefix("nl") { return 8 }
        if lang.hasPrefix("pt") { return 9 }
        if lang.hasPrefix("ru") { return 10 }
        return 1
    }

    // MARK: Import (file picker / "Open in Bifold")

    /// Copies ROMs into Games/, installs CIA files into the emulated SD card. Files that already
    /// live in the app's own folder (opened from the Files app) are handled by the folder scan.
    func importFiles(_ urls: [URL]) {
        let docs = Self.documentsDirectory.standardizedFileURL.path
        let outside = urls.filter { !$0.standardizedFileURL.path.hasPrefix(docs + "/") }
        guard !outside.isEmpty else { refresh(); return }
        let known = Dictionary(games.map { ($0.uniqueID, $0.title) }, uniquingKeysWith: { a, _ in a })
        Task.detached(priority: .userInitiated) {
            var messages: [String] = []
            var installed: [InstalledCIA] = []
            for url in outside {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let ext = url.pathExtension.lowercased()
                if GameLibrary.ciaExtensions.contains(ext) {
                    var info = AZCIAInfo()
                    let hasInfo = az_get_cia_info(url.path, &info)
                    let name = url.lastPathComponent
                    await MainActor.run {
                        GameLibrary.shared.installingName = name
                        GameLibrary.shared.installProgress = 0
                    }
                    let code = await GameLibrary.installCIAFile(url.path)
                    if code == 0 {
                        installed.append(InstalledCIA(name: name, info: hasInfo ? info : nil))
                    } else {
                        messages.append("安装失败 \(name)：\(GameLibrary.ciaError(code))")
                    }
                } else {
                    let dest = GameLibrary.gamesDirectory.appendingPathComponent(url.lastPathComponent)
                    do {
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.copyItem(at: url, to: dest)
                        messages.append("已导入 \(url.lastPathComponent)")
                    } catch {
                        messages.append("导入失败 \(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            }
            let summary = messages.joined(separator: "\n")
            let done = installed
            await MainActor.run {
                if !summary.isEmpty { self.post(summary) }
                self.pickerInstalled += done
                self.installProgress = nil
                self.installingName = nil
                self.refresh()
            }
        }
    }

    func delete(_ game: Game) {
        guard !game.isInstalledTitle else { return }
        try? FileManager.default.removeItem(at: game.url)
        refresh()
    }

    nonisolated static func ciaError(_ code: Int32) -> String {
        switch code {
        case 2: return "内容已加密。Azahar 只能安装解密过的 CIA，请先在自己的 3DS 上用 GodMode9 等工具解密"
        case 3: return "文件无效"
        case 4: return "找不到文件"
        case 5: return "已取消"
        default: return "未知错误"
        }
    }
}
