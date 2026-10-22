#if DEBUG
import AzaharCore
import Foundation
import UIKit

/// Debug-only unattended test hooks, driven by launch arguments:
///   -autoboot <file name in Games>   boot that game as soon as the library has scanned it
///   -autoshot <seconds>              then save a screenshot after that many seconds
/// Everything is logged with NSLog("BifoldAuto …") and appended to Documents/autotest.log,
/// so a test run on a device needs no taps.
enum AutoTest {
    static var bootFile: String? { UserDefaults.standard.string(forKey: "autoboot") }
    static var shotDelay: Double { UserDefaults.standard.double(forKey: "autoshot") }
    @MainActor private static var didBoot = false

    static func log(_ message: String) {
        NSLog("BifoldAuto %@", message)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("autotest.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Picks the game to auto-boot once it shows up in the library (polls for up to 15 s).
    @MainActor static func waitForBootGame(in library: GameLibrary, _ play: @escaping (Game) -> Void) {
        guard let file = bootFile, !file.isEmpty, !didBoot else { return }
        didBoot = true
        log("autoboot requested: \(file); jit=\(JITHelper.statusText)")
        Task { @MainActor in
            for _ in 0..<60 {
                if let g = library.games.first(where: { $0.url.lastPathComponent == file || $0.titleIDString == file.uppercased() }) {
                    for x in library.games {
                        log("library: \(x.title) [\(x.titleIDString)] installed=\(x.isInstalledTitle) update=\(x.updateVersion.map { Game.versionString($0) } ?? "-") dlc=\(x.hasDLC)")
                    }
                    if let m = library.notice { log("import notice: \(m.replacingOccurrences(of: "\n", with: " | "))") }
                    log("booting \(g.title)")
                    play(g)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            log("autoboot: \(file) not found in library (\(library.games.count) games)")
        }
    }

    /// Called once the session has started: logs perf every 2 s and takes the screenshot.
    @MainActor static func sessionStarted(core: EmulatorCore) {
        guard bootFile != nil else { return }
        Task { @MainActor in
            let delay = shotDelay > 0 ? shotDelay : 8
            var waited = 0.0
            while waited < delay + 4 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                waited += 2
                var s = AZPerfStats()
                let ok = az_get_perf_stats(&s)
                log(String(format: "t=%.0fs running=%d perf=%d fps=%.1f speed=%.0f%% sw_renderer=%d",
                           waited, az_is_running() ? 1 : 0, ok ? 1 : 0, s.game_fps,
                           s.emulation_speed * 100, az_is_software_renderer() ? 1 : 0)
                    + " state=\(String(describing: core.state))")
                if waited >= delay && waited < delay + 2 {
                    if let url = await core.screenshot() {
                        log("screenshot \(url.lastPathComponent)")
                    } else {
                        log("screenshot failed")
                    }
                }
            }
            log("done")
        }
    }
}

// MARK: - Remote play (Debug only)

/// Lets a test driver "play" on a device without touching the screen: it copies a command file
/// to Documents/remote/cmd.txt (first line `seq N`, last line `end`); the app runs it and
/// appends `done N` to Documents/remote/log.txt. Enabled with the launch argument `-remote YES`.
///
///   press A [ms]          tap a button (A B X Y L R ZL ZR START SELECT HOME UP DOWN LEFT RIGHT)
///   hold A ms             same, explicit duration
///   touch x y [ms]        tap the bottom screen at 3DS coordinates (0…319, 0…239)
///   drag x1 y1 x2 y2 ms   swipe on the bottom screen
///   stick x y ms          circle pad (-1…1), then centre
///   combo A+B+X ms        hold several buttons together
///   clean                 delete the screenshots in Documents/remote
///   wait ms
///   shot name             screenshot to Documents/remote/name.png
///   save N / load N       save state slot N (1…10) / load it
///   speed P               emulation speed in percent, 0 = normal (fast-forward)
///   burst name k ms       k screenshots name-1…k, ms apart
///   walk x y ms name      screenshot name-0, hold the stick, screenshot name-1
///   pause / resume        same as the menu (e.g. after an interruption paused the game)
///   status                log speed / JIT / running state
///   mem                   log the process memory footprint (what jetsam counts)
///   heap                  log the big malloc blocks by size (leak hunting)
/// Every batch also logs `mem <MB>` before `done N`, and a sampler appends
/// "<unix time> <footprint MB>" to Documents/remote/mem.txt every 5 s.
enum RemotePlay {
    /// phys_footprint in MB: the number iOS compares with the per-app memory limit.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "remote") }
    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("remote", isDirectory: true)
    }
    private static var started = false

    static func log(_ line: String) {
        let url = dir.appendingPathComponent("log.txt")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Breakdown to tell a heap leak from a GPU/IOSurface one: footprint, malloc in use,
    /// graphics-tagged (Metal) memory, compressed, and what is left before jetsam.
    static func memDetail() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var zone = malloc_statistics_t()
        malloc_zone_statistics(nil, &zone)
        func mb<T: BinaryInteger>(_ v: T) -> Int { Int(Int64(v) / 1_048_576) }
        return "fp=\(mb(info.phys_footprint)) malloc=\(mb(zone.size_in_use))"
            + " gfx=\(mb(info.ledger_tag_graphics_footprint) + mb(info.ledger_tag_graphics_footprint_compressed))"
            + " internal=\(mb(info.internal)) compressed=\(mb(info.compressed)) left=\(mb(info.limit_bytes_remaining))"
    }

    @MainActor static func startIfRequested() {
        guard enabled, !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("remote ready")
        az_debug_track_big_allocs(4 << 20)   // remember where every block ≥ 4 MB came from ("heap")
        Thread.detachNewThread {
            let url = dir.appendingPathComponent("mem.txt")
            while true {
                let line = "\(Int(Date().timeIntervalSince1970)) \(footprintMB())\n"
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
                } else {
                    try? Data(line.utf8).write(to: url)
                }
                Thread.sleep(forTimeInterval: 5)
            }
        }
        Thread.detachNewThread {
            let cmd = dir.appendingPathComponent("cmd.txt")
            while true {
                Thread.sleep(forTimeInterval: 0.3)
                guard let text = try? String(contentsOf: cmd, encoding: .utf8),
                      text.contains("\nend") else { continue }
                try? FileManager.default.removeItem(at: cmd)
                run(text)
            }
        }
    }

    private static let buttons: [String: AZButton] = [
        "A": AZ_BUTTON_A, "B": AZ_BUTTON_B, "X": AZ_BUTTON_X, "Y": AZ_BUTTON_Y,
        "L": AZ_BUTTON_L, "R": AZ_BUTTON_R, "ZL": AZ_BUTTON_ZL, "ZR": AZ_BUTTON_ZR,
        "START": AZ_BUTTON_START, "SELECT": AZ_BUTTON_SELECT, "HOME": AZ_BUTTON_HOME,
        "UP": AZ_BUTTON_UP, "DOWN": AZ_BUTTON_DOWN, "LEFT": AZ_BUTTON_LEFT, "RIGHT": AZ_BUTTON_RIGHT,
    ]

    private static func ms(_ v: Int) { Thread.sleep(forTimeInterval: Double(v) / 1000) }

    /// Bottom-screen 3DS coordinates → the surface's framebuffer coordinates used by az_touch_*.
    private static func touchPoint(_ x: Double, _ y: Double) -> (Float, Float)? {
        var top = AZScreenRect(), bottom = AZScreenRect()
        for _ in 0..<20 {
            if az_get_screen_rects(&top, &bottom), bottom.enabled, bottom.width > 0 {
                return (bottom.x + Float(x / 320) * bottom.width, bottom.y + Float(y / 240) * bottom.height)
            }
            ms(20)
        }
        return nil
    }

    private static func run(_ text: String) {
        var seq = "?"
        for raw in text.split(separator: "\n") {
            let p = raw.split(separator: " ").map(String.init)
            guard let op = p.first?.lowercased() else { continue }
            let n = { (i: Int, d: Int) -> Int in p.count > i ? Int(p[i]) ?? d : d }
            let f = { (i: Int) -> Double in p.count > i ? Double(p[i]) ?? 0 : 0 }
            switch op {
            case "seq": seq = p.count > 1 ? p[1] : "?"
            case "press", "hold":
                guard p.count > 1, let b = buttons[p[1].uppercased()] else { log("bad button \(raw)"); continue }
                az_button(b, true); ms(n(2, 120)); az_button(b, false); ms(80)
            case "combo":
                // combo UP+B+X ms: hold several buttons together (e.g. a game's delete-save combo)
                let names = p.count > 1 ? p[1].uppercased().split(separator: "+").map(String.init) : []
                let bs = names.compactMap { buttons[$0] }
                guard !bs.isEmpty, bs.count == names.count else { log("bad combo \(raw)"); continue }
                bs.forEach { az_button($0, true) }; ms(n(2, 1500)); bs.forEach { az_button($0, false) }; ms(80)
            case "mp":
                // mp host NAME [public] | lan | joinlan | join ADDR [PORT] | chat TEXT | info | leave
                //    | nick NAME | lobby URL
                let sub = p.count > 1 ? p[1] : "info"
                let rest = p.count > 2 ? p[2...].joined(separator: " ") : ""
                DispatchQueue.main.sync {
                    let mp = MultiplayerManager.shared
                    switch sub {
                    case "host":
                        mp.host(name: rest.replacingOccurrences(of: " public", with: ""), port: az_mp_default_port(),
                                password: "", maxPlayers: 4, isPublic: rest.hasSuffix(" public"),
                                preferredGame: EmulatorCore.shared.currentGame)
                    case "lan": mp.lan.startBrowsing()
                    case "joinlan":
                        if let r = mp.lan.rooms.first { mp.join(address: r.addresses.first ?? "", port: r.port, password: "") }
                        else { log("mp no lan room") }
                    case "join":
                        let a = rest.split(separator: " ")
                        mp.join(address: a.first.map(String.init) ?? "", port: a.count > 1 ? UInt16(a[1]) ?? az_mp_default_port() : az_mp_default_port(), password: "")
                    case "chat": mp.send(rest)
                    case "leave": mp.leave()
                    case "nick": AppSettings.shared.nickname = rest
                    case "lobby": AppSettings.shared.lobbyURL = rest; EmulatorCore.shared.reloadSettings(); mp.refreshLobby()
                    default: break
                    }
                }
                ms(sub == "info" ? 0 : 300)
                DispatchQueue.main.sync {
                    let mp = MultiplayerManager.shared
                    log("mp state=\(mp.state.rawValue) hosting=\(mp.isHosting) busy=\(mp.isBusy) room=\(mp.roomName) err=\(mp.lastError ?? "-") lobbyErr=\(mp.lobbyError ?? "-")")
                    log("mp members=" + mp.members.map { "\($0.nickname)[\($0.game)]" }.joined(separator: ","))
                    log("mp lan=" + mp.lan.rooms.map { "\($0.name)@\($0.addresses.joined(separator: "/")):\($0.port) \($0.players)/\($0.maxPlayers)" }.joined(separator: "; "))
                    log("mp lobby=" + mp.lobbyRooms.map { "\($0.name)@\($0.address):\($0.port)" }.joined(separator: "; "))
                    for c in mp.chat.suffix(4) { log("mp chat \(c.nickname): \(c.text)") }
                }
            case "clean":
                // delete old screenshots in Documents/remote
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                let pngs = files.filter { $0.pathExtension == "png" }
                pngs.forEach { try? FileManager.default.removeItem(at: $0) }
                log("clean removed \(pngs.count)")
            case "touch":
                guard let (x, y) = touchPoint(f(1), f(2)) else { log("no bottom screen"); continue }
                _ = az_touch_begin(x, y); ms(n(3, 150)); az_touch_end(); ms(80)
            case "drag":
                guard let (x1, y1) = touchPoint(f(1), f(2)), let (x2, y2) = touchPoint(f(3), f(4)) else { continue }
                let total = n(5, 400), steps = max(4, total / 16)
                _ = az_touch_begin(x1, y1)
                for i in 1...steps {
                    let t = Float(i) / Float(steps)
                    az_touch_move(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t); ms(total / steps)
                }
                az_touch_end(); ms(80)
            case "stick":
                az_stick(AZ_STICK_CIRCLE_PAD, Float(f(1)), Float(f(2))); ms(n(3, 300))
                az_stick(AZ_STICK_CIRCLE_PAD, 0, 0); ms(80)
            case "wait": ms(n(1, 500))
            case "save", "load":
                // Save states (slots 1…10): rewind after a wrong turn instead of replaying.
                let slot = Int32(n(1, 1))
                DispatchQueue.main.sync {
                    if op == "save" { EmulatorCore.shared.saveState(slot: Int(slot)) } else { EmulatorCore.shared.loadState(slot: Int(slot)) }
                }
                ms(op == "save" ? 1500 : 2500)
                log("\(op) \(slot)")
            case "speed":
                // Emulation speed in percent (fast-forward through dialogue); 0 = normal.
                az_set_speed_override(Double(n(1, 0)))
                log("speed \(n(1, 0))")
            case "burst":
                // burst name count interval_ms: several frames, e.g. to watch a walk.
                let name = p.count > 1 ? p[1] : "b"
                let count = n(2, 4), gap = n(3, 300)
                for i in 1...max(1, count) {
                    _ = az_screenshot(dir.appendingPathComponent("\(name)-\(i).png").path)
                    if i < count { ms(gap) }
                }
                log("burst \(name) \(count)")
            case "walk":
                // walk x y ms name: hold the stick and take a frame before/after (motion check).
                let name = p.count > 4 ? p[4] : "w"
                _ = az_screenshot(dir.appendingPathComponent("\(name)-0.png").path)
                az_stick(AZ_STICK_CIRCLE_PAD, Float(f(1)), Float(f(2))); ms(n(3, 600))
                az_stick(AZ_STICK_CIRCLE_PAD, 0, 0); ms(250)
                _ = az_screenshot(dir.appendingPathComponent("\(name)-1.png").path)
                log("walk \(name)")
            case "pause", "resume":
                let paused = op == "pause"
                DispatchQueue.main.sync { EmulatorCore.shared.setPaused(paused) }
            case "shot":
                let name = p.count > 1 ? p[1] : "shot"
                let url = dir.appendingPathComponent("\(name).png")
                // Never leave an older capture under this name: a failed shot must not look fresh.
                try? FileManager.default.removeItem(at: url)
                let ok = az_screenshot(url.path)
                log("shot \(name) \(ok ? "ok" : "failed")")
            case "status":
                var st = AZPerfStats()
                _ = az_get_perf_stats(&st)
                var ui = ""
                DispatchQueue.main.sync {
                    let app = UIApplication.shared
                    let states = ["active", "inactive", "background"]
                    ui = "app=\(states[min(app.applicationState.rawValue, 2)])"
                    var vc = app.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
                    var chain: [String] = []
                    while let c = vc { chain.append(String(describing: type(of: c)).prefix(40).description); vc = c.presentedViewController }
                    ui += " ui=" + chain.joined(separator: ">")
                }
                let clock = az_debug_console_clock_offset_ms()
                log((clock == Int64.min ? "" : "clock=\(clock / 1000)s ") + String(format: "status running=%d paused=%d speed=%.0f%% fps=%.1f jit=%d ", az_is_running() ? 1 : 0,
                           az_is_paused() ? 1 : 0, st.emulation_speed * 100, st.game_fps, Int(az_jit_status().rawValue)) + ui)
            case "mem": log("mem \(memDetail())")
            case "heap":
                // Big live malloc blocks by size: what is left behind after save/load.
                if let c = az_debug_heap() { log("heap \(String(cString: c))"); az_free(c) }
            case "end": break
            default: log("unknown \(raw)")
            }
        }
        log("mem \(footprintMB())")
        log("done \(seq)")
    }
}
#endif
