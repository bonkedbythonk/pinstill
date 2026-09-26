import Foundation

public struct Board: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let privacy: String
    public let path: String
    public let pinCount: Int

    public init(id: String, name: String, privacy: String, path: String, pinCount: Int) {
        self.id = id
        self.name = name
        self.privacy = privacy
        self.path = path
        self.pinCount = pinCount
    }

    public var isSecret: Bool { privacy != "public" }
}

public struct BoardPage: Sendable {
    public let pins: [Pin]
    /// Items that aren't usable images (videos, idea pins without an original image). Stories are ignored entirely.
    public let unusable: [Pin]
    /// Pass back as `bookmarks: [bookmark]` for the next page; nil on the last page.
    public let bookmark: String?
}

public enum PinterestAPIError: Error, CustomStringConvertible {
    case badResponse(String)
    public var description: String {
        switch self {
        case .badResponse(let why): "Unexpected Pinterest response: \(why)"
        }
    }
}

/// Pinterest's internal web endpoints (`/resource/<Name>/get/`), as used by pinterest.com itself.
/// Undocumented: if Pinterest changes them, this file and `PinterestSession` are what break.
public enum PinterestAPI {
    /// `X-Pinterest-PWS-Handler` is required; requests without it get 403.
    public static let headers: [String: String] = [
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest",
        "X-Pinterest-PWS-Handler": "www/index.js",
    ]

    public static let userSettings = "UserSettingsResource"
    public static let boards = "BoardsResource"
    public static let boardFeed = "BoardFeedResource"

    public static func boardsOptions(username: String) -> [String: Any] {
        ["username": username, "page_size": 100, "privacy_filter": "all",
         "sort": "last_pinned_to", "field_set_key": "profile_grid_item"]
    }

    public static func boardFeedOptions(boardID: String, bookmark: String?) -> [String: Any] {
        var options: [String: Any] = ["board_id": boardID, "page_size": 25, "field_set_key": "react_grid_pin"]
        if let bookmark { options["bookmarks"] = [bookmark] }
        return options
    }

    // MARK: Parsing

    public static func parseUsername(_ data: Data) throws -> String? {
        try envelope(UserSettings.self, data).username
    }

    public static func parseBoards(_ data: Data) throws -> [Board] {
        try envelope([Lossy<RawBoard>].self, data).compactMap(\.value).compactMap { raw in
            guard raw.type == nil || raw.type == "board", let url = raw.url else { return nil }
            return Board(id: raw.id, name: raw.name ?? "Untitled", privacy: raw.privacy ?? "public",
                         path: url, pinCount: raw.pin_count ?? 0)
        }
    }

    public static func parseBoardFeed(_ data: Data) throws -> BoardPage {
        let response = try JSONDecoder().decode(Envelope<[Lossy<RawFeedItem>]>.self, from: data).resource_response
        var pins: [Pin] = [], unusable: [Pin] = []
        for item in (response.data ?? []).compactMap(\.value) where item.type == "pin" {
            let title = item.grid_title ?? item.title ?? ""
            let pinURL = URL(string: "https://www.pinterest.com/pin/\(item.id)/")!
            let thumb = item.images?["236x"]?.flatMap(\.url).flatMap(URL.init(string:))
            if let orig = item.images?["orig"] ?? nil, let url = orig.url.flatMap(URL.init(string:)) {
                pins.append(Pin(id: item.id, title: title, pinURL: pinURL, imageURL: url,
                                width: orig.width, height: orig.height, thumbnailURL: thumb))
            } else {
                unusable.append(Pin(id: item.id, title: title, pinURL: pinURL, imageURL: pinURL,
                                    width: nil, height: nil, thumbnailURL: thumb))
            }
        }
        let bookmark = response.bookmark.flatMap { $0.isEmpty || $0 == "-end-" ? nil : $0 }
        return BoardPage(pins: pins, unusable: unusable, bookmark: bookmark)
    }

    private static func envelope<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let value = try JSONDecoder().decode(Envelope<T>.self, from: data).resource_response.data else {
            throw PinterestAPIError.badResponse("no data")
        }
        return value
    }
}

// MARK: - Wire types (only the fields we use; everything optional because Pinterest's shapes vary)

private struct Envelope<T: Decodable>: Decodable {
    struct Response: Decodable {
        let data: T?
        let bookmark: String?
    }
    let resource_response: Response
}

/// Decodes to nil instead of failing the whole array when one element has an unexpected shape.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct UserSettings: Decodable {
    let username: String?
}

private struct RawBoard: Decodable {
    let id: String
    let name: String?
    let privacy: String?
    let url: String?
    let pin_count: Int?
    let type: String?
}

private struct RawImage: Decodable {
    let url: String?
    let width: Int?
    let height: Int?
}

private struct RawFeedItem: Decodable {
    let id: String
    let type: String?
    let title: String?
    let grid_title: String?
    let images: [String: RawImage?]?

    enum CodingKeys: String, CodingKey { case id, type, title, grid_title, images }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try? c.decode(String.self, forKey: .type)
        // Stories use an object for `title`; pins use a string.
        title = try? c.decode(String.self, forKey: .title)
        grid_title = try? c.decode(String.self, forKey: .grid_title)
        images = try? c.decode([String: RawImage?].self, forKey: .images)
    }
}
