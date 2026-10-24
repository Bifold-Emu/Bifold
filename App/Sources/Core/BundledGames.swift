import Foundation

/// A free homebrew game shipped inside the app (App/Bundled, copied into the bundle as a folder).
/// All of them are open source with licenses that allow redistribution; the catalog keeps what
/// each license asks for (author, license text, where the source is).
struct BundledGame: Codable, Hashable, Identifiable {
    /// File name inside Bundled/, also the stable identity used for hiding.
    let file: String
    let title: String
    let author: String
    let license: String
    /// License text inside Bundled/licenses/.
    let licenseFile: String
    let source: String
    /// What the game is useful for, shown on the licenses page.
    let about: String
    /// Extra attribution or license notes (assets under another license, …).
    let notes: String?

    var id: String { file }
}

enum BundledCatalog {
    static var directory: URL? {
        Bundle.main.url(forResource: "Bundled", withExtension: nil)
    }

    static let all: [BundledGame] = {
        guard let url = directory?.appendingPathComponent("catalog.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BundledGame].self, from: data)) ?? []
    }()

    static func url(of game: BundledGame) -> URL? {
        directory?.appendingPathComponent(game.file)
    }

    static func licenseText(of game: BundledGame) -> String {
        guard let url = directory?.appendingPathComponent("licenses").appendingPathComponent(game.licenseFile),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: Hidden games

    /// Removing a bundled game from the library only hides it: the file is part of the signed app
    /// and cannot be deleted. Settings › 预置自制游戏 shows them again.
    private static let hiddenKey = "hiddenBundledGames"

    static var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    static func setHidden(_ files: Set<String>) {
        UserDefaults.standard.set(Array(files).sorted(), forKey: hiddenKey)
    }
}
