import Foundation

public struct Pin: Sendable, Hashable, Codable {
    public let id: String
    public let title: String
    public let pinURL: URL
    /// Full-size image when known (`images.orig`), otherwise the best URL the source gave.
    public let imageURL: URL
    /// Original pixel size when the source reports it, so shape can be checked before downloading.
    public let width: Int?
    public let height: Int?
    public let thumbnailURL: URL?

    public init(id: String, title: String, pinURL: URL, imageURL: URL,
                width: Int?, height: Int?, thumbnailURL: URL?) {
        self.id = id
        self.title = title
        self.pinURL = pinURL
        self.imageURL = imageURL
        self.width = width
        self.height = height
        self.thumbnailURL = thumbnailURL
    }
}
