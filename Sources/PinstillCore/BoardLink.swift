import Foundation

/// A Pinterest board feeding a folder of wallpapers. Each link keeps its own library of seen
/// pins, so boards can't confuse each other's history.
public struct BoardLink: Sendable, Codable, Hashable, Identifiable {
    public var board: Board
    public var folderPath: String
    /// File name of this board's library next to the app's other data.
    public var libraryName: String

    public var id: String { board.id }
    public var folder: URL { URL(filePath: folderPath) }

    public init(board: Board, folder: URL, libraryName: String) {
        self.board = board
        self.folderPath = Self.plainPath(folder)
        self.libraryName = libraryName
    }

    public mutating func setFolder(_ folder: URL) { folderPath = Self.plainPath(folder) }

    private static func plainPath(_ folder: URL) -> String {
        let path = folder.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public static func libraryName(for boardID: String) -> String {
        "library-\(boardID.filter { $0.isLetter || $0.isNumber }).json"
    }
}

public enum BoardLinks {
    /// What older versions stored: one board, one folder, and everything in `library.json`.
    public static func migrate(board: Board?, folder: URL, legacyLibraryName: String) -> [BoardLink] {
        board.map { [BoardLink(board: $0, folder: folder, libraryName: legacyLibraryName)] } ?? []
    }

    /// The library file for a board being linked. The board an older version was set up with keeps its
    /// history in `library.json`, so linking it again later must not start over.
    public static func libraryName(for boardID: String, legacyBoardID: String?, legacyName: String) -> String {
        boardID == legacyBoardID ? legacyName : BoardLink.libraryName(for: boardID)
    }

    /// `~/Pictures/Pinstill` + "Anime / scenery" → `~/Pictures/Pinstill Anime - scenery`, next to the
    /// base folder rather than inside it (a rotating folder would pick up the subfolder's images).
    public static func defaultFolder(for board: Board, base: URL, existing: [BoardLink]) -> URL {
        let parent = base.deletingLastPathComponent()
        let name = "\(base.lastPathComponent) \(cleanName(board.name))"
        var candidate = parent.appending(path: name, directoryHint: .isDirectory)
        var n = 2
        while folderProblem(candidate, existing: existing, ignoring: nil) != nil {
            candidate = parent.appending(path: "\(name) \(n)", directoryHint: .isDirectory)
            n += 1
        }
        return candidate
    }

    public static func cleanName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Board" : result
    }

    /// Why `folder` can't be used for another board: the same folder, or one inside the other
    /// (macOS rotating a folder would also pick up the images of a folder inside it).
    public static func folderProblem(_ folder: URL, existing: [BoardLink], ignoring boardID: String?) -> String? {
        let path = normalized(folder)
        for link in existing where link.id != boardID {
            let other = normalized(link.folder)
            if path == other { return "\(link.board.name) already uses that folder." }
            if path.hasPrefix(other + "/") || other.hasPrefix(path + "/") {
                return "That folder is inside, or contains, the folder of \(link.board.name)."
            }
        }
        return nil
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }
}
