import Foundation
import Testing
@testable import PinstillCore

private func board(_ id: String, _ name: String) -> Board {
    Board(id: id, name: name, privacy: "secret", path: "/u/\(id)/", pinCount: 3)
}

@Test func anOldSingleBoardSetupBecomesOneLinkKeepingItsLibrary() {
    let folder = URL(filePath: "/Users/me/Pictures/Pinstill", directoryHint: .isDirectory)
    let links = BoardLinks.migrate(board: board("1", "Walls"), folder: folder, legacyLibraryName: "library.json")
    #expect(links.count == 1)
    #expect(links[0].libraryName == "library.json")
    #expect(links[0].folderPath == "/Users/me/Pictures/Pinstill")
    #expect(BoardLinks.migrate(board: nil, folder: folder, legacyLibraryName: "library.json").isEmpty)
}

@Test func linksSurviveEncoding() throws {
    let link = BoardLink(board: board("7", "Travel"), folder: URL(filePath: "/tmp/x", directoryHint: .isDirectory),
                         libraryName: BoardLink.libraryName(for: "7"))
    let decoded = try JSONDecoder().decode([BoardLink].self, from: JSONEncoder().encode([link]))
    #expect(decoded == [link])
    #expect(link.libraryName == "library-7.json")
}

@Test func anotherBoardGetsAFolderNextToTheFirstWithACleanName() {
    let base = URL(filePath: "/Users/me/Pictures/Pinstill", directoryHint: .isDirectory)
    let first = BoardLink(board: board("1", "Walls"), folder: base, libraryName: "library.json")
    let folder = BoardLinks.defaultFolder(for: board("2", "Anime / scenery: 2026"), base: base, existing: [first])
    #expect(folder.path(percentEncoded: false) == "/Users/me/Pictures/Pinstill Anime - scenery- 2026/")
    // Same name again: numbered, never shared.
    let second = BoardLink(board: board("2", "Anime / scenery: 2026"), folder: folder, libraryName: "library-2.json")
    let third = BoardLinks.defaultFolder(for: board("3", "Anime / scenery: 2026"), base: base, existing: [first, second])
    #expect(third != folder)
}

@Test func foldersCantBeSharedOrNested() {
    let base = URL(filePath: "/Users/me/Pictures/Pinstill", directoryHint: .isDirectory)
    let link = BoardLink(board: board("1", "Walls"), folder: base, libraryName: "library.json")
    #expect(BoardLinks.folderProblem(base, existing: [link], ignoring: nil) != nil)
    #expect(BoardLinks.folderProblem(base.appending(path: "More"), existing: [link], ignoring: nil) != nil)
    #expect(BoardLinks.folderProblem(base.deletingLastPathComponent(), existing: [link], ignoring: nil) != nil)
    #expect(BoardLinks.folderProblem(URL(filePath: "/Users/me/Pictures/Pinstill 2"), existing: [link], ignoring: nil) == nil)
    // Changing a board's own folder to somewhere it already is isn't a conflict.
    #expect(BoardLinks.folderProblem(base, existing: [link], ignoring: "1") == nil)
}

@Test func theBoardFromAnOlderVersionKeepsItsLibraryWhenLinkedAgain() {
    #expect(BoardLinks.libraryName(for: "42", legacyBoardID: "42", legacyName: "library.json") == "library.json")
    #expect(BoardLinks.libraryName(for: "7", legacyBoardID: "42", legacyName: "library.json") == "library-7.json")
    #expect(BoardLinks.libraryName(for: "7", legacyBoardID: nil, legacyName: "library.json") == "library-7.json")
}
