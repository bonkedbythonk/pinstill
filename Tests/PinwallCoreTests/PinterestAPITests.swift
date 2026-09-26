import Foundation
import Testing
@testable import PinwallCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func parsesUsername() throws {
    #expect(try PinterestAPI.parseUsername(fixture("user-settings")) == "example_user")
}

@Test func parsesBoardsIncludingSecret() throws {
    let boards = try PinterestAPI.parseBoards(fixture("boards"))
    #expect(boards.map(\.name) == ["Pinwall", "Desk wallpapers", "Travel"])
    #expect(boards[0].id == "200000000000000001")
    #expect(boards[0].isSecret)
    #expect(!boards[2].isSecret)
    #expect(boards[1].pinCount == 55)
}

@Test func parsesBoardFeedPins() throws {
    let page = try PinterestAPI.parseBoardFeed(fixture("board-feed"))
    #expect(page.pins.map(\.id) == ["300000000000000001", "300000000000000002"])

    let landscape = page.pins[1]
    #expect(landscape.width == 1920 && landscape.height == 1200)
    #expect(landscape.imageURL.absoluteString.contains("/originals/"))
    #expect(landscape.thumbnailURL?.absoluteString.contains("/236x/") == true)
    #expect(landscape.pinURL.absoluteString == "https://www.pinterest.com/pin/300000000000000002/")

    #expect(page.pins[0].title == "ദ്ദി(˵ •̀ ᴗ - ˵ ) ✧")
}

@Test func separatesPinsWithoutOriginalAndIgnoresStories() throws {
    let page = try PinterestAPI.parseBoardFeed(fixture("board-feed"))
    #expect(page.unusable.map(\.id) == ["300000000000000003"])
    #expect(!page.pins.contains { $0.id == "400000000000000001" })
}

@Test func bookmarkMarksMorePages() throws {
    #expect(try PinterestAPI.parseBoardFeed(fixture("board-feed")).bookmark != nil)
    let end = try PinterestAPI.parseBoardFeed(fixture("board-feed-end"))
    #expect(end.bookmark == nil)
    #expect(end.pins.isEmpty)
}

@Test func feedOptionsCarryBookmark() {
    let first = PinterestAPI.boardFeedOptions(boardID: "1", bookmark: nil)
    #expect(first["bookmarks"] == nil)
    let next = PinterestAPI.boardFeedOptions(boardID: "1", bookmark: "abc")
    #expect(next["bookmarks"] as? [String] == ["abc"])
}
