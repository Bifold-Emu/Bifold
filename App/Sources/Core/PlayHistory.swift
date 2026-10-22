import Foundation
import UIKit

/// When each game was last played, for how long in total, and small pictures of where the player
/// left off: the last scene (shown on the library's "continue" card) and one per save-state slot.
/// Pictures are the top screen only, taken from a core screenshot while the game is running.
@MainActor
final class PlayHistory: ObservableObject {
    static let shared = PlayHistory()

    struct Entry: Codable {
        var lastPlayed: Date
        var seconds: Double
    }

    @Published private(set) var entries: [String: Entry] = [:]
    /// Bumped whenever a picture changes so views reload it.
    @Published private(set) var pictureVersion = 0

    private let key = "playHistory"
    private var sessionStart: Date?
    private var sessionGame: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let e = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = e
        }
    }

    static var thumbsDirectory: URL {
        EmulatorCore.shared.userDirectory.appendingPathComponent("thumbs", isDirectory: true)
    }

    static func lastSceneURL(_ titleID: String) -> URL { thumbsDirectory.appendingPathComponent("\(titleID)-last.png") }
    static func slotURL(_ titleID: String, _ slot: Int) -> URL { thumbsDirectory.appendingPathComponent("\(titleID).\(slot).png") }

    func entry(for game: Game) -> Entry? { entries[game.titleIDString] }

    /// The most recently played of `games`.
    func mostRecent(in games: [Game]) -> Game? {
        games.filter { entries[$0.titleIDString] != nil }
            .max { entries[$0.titleIDString]!.lastPlayed < entries[$1.titleIDString]!.lastPlayed }
    }

    func sessionStarted(_ game: Game) {
        sessionStart = Date()
        sessionGame = game.titleIDString
        var e = entries[game.titleIDString] ?? Entry(lastPlayed: Date(), seconds: 0)
        e.lastPlayed = Date()
        entries[game.titleIDString] = e
        save()
    }

    func sessionEnded() {
        guard let start = sessionStart, let id = sessionGame else { return }
        var e = entries[id] ?? Entry(lastPlayed: Date(), seconds: 0)
        e.seconds += Date().timeIntervalSince(start)
        e.lastPlayed = Date()
        entries[id] = e
        sessionStart = nil
        sessionGame = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: Pictures

    /// Takes a screenshot of the running game and keeps its top screen as the "last scene".
    /// Returns the picture so a following save state can reuse it.
    func captureLastScene(for game: Game) async -> UIImage? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bifold-scene.png")
        try? FileManager.default.removeItem(at: tmp)
        guard await EmulatorCore.shared.capture(to: tmp),
              let full = UIImage(contentsOfFile: tmp.path),
              let top = Self.topScreen(of: full) else { return nil }
        store(top, at: Self.lastSceneURL(game.titleIDString))
        return top
    }

    func storeSlotPicture(_ image: UIImage, game: Game, slot: Int) {
        store(image, at: Self.slotURL(game.titleIDString, slot))
    }

    private func store(_ image: UIImage, at url: URL) {
        try? FileManager.default.createDirectory(at: Self.thumbsDirectory, withIntermediateDirectories: true)
        if let data = image.pngData() { try? data.write(to: url, options: .atomic) }
        pictureVersion += 1
    }

    /// Core screenshots hold both screens: side by side on Vulkan (wider than tall), stacked on
    /// the software renderer. The top screen is 5:3.
    nonisolated static func topScreen(of image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = w > h ? CGRect(x: 0, y: 0, width: min(w, h * 5 / 3), height: h)
                         : CGRect(x: 0, y: 0, width: w, height: min(h, w * 3 / 5))
        guard let crop = cg.cropping(to: rect) else { return nil }
        let size = CGSize(width: 400, height: 240)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Save states on disk (readable without a running game)

    struct SlotInfo: Identifiable {
        let slot: Int
        let date: Date
        var id: Int { slot }
    }

    /// Save states of `game` from <user>/states/<TITLEID>.<NN>.cst, newest first.
    func saveStates(of game: Game) -> [SlotInfo] {
        let dir = EmulatorCore.shared.userDirectory.appendingPathComponent("states", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let prefix = game.titleIDString.uppercased() + "."
        return files.compactMap { url -> SlotInfo? in
            let name = url.lastPathComponent.uppercased()
            guard name.hasPrefix(prefix), url.pathExtension.lowercased() == "cst",
                  let slot = Int(name.dropFirst(prefix.count).prefix(2)),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return SlotInfo(slot: slot, date: date)
        }
        .sorted { $0.date > $1.date }
    }
}

extension Double {
    /// "7 小时" / "25 分钟".
    var playTimeText: String {
        let minutes = Int(self / 60)
        if minutes < 60 { return "\(max(minutes, 1)) 分钟" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f 小时", hours) : "\(Int(hours)) 小时"
    }
}

extension Date {
    /// "今天 09:33" / "昨天 22:10" / "10月20日".
    var shortPlayedText: String {
        let cal = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(self) { return "今天 \(time)" }
        if cal.isDateInYesterday(self) { return "昨天 \(time)" }
        return formatted(.dateTime.month().day())
    }
}
