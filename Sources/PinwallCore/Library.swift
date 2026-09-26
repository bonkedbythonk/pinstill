import Foundation

public enum PinStatus: String, Sendable, Codable {
    case done
    case skippedShape
    /// Video / idea pin without an original image.
    case skippedNotImage
    /// Already on the board when it was linked and the user chose not to import it.
    case skippedExisting
    case failed

    /// Seen pins are never processed again; failed ones are retried on the next sync.
    public var isSeen: Bool { self != .failed }
}

public struct PinRecord: Sendable, Codable, Identifiable {
    public let pin: Pin
    public var status: PinStatus
    public var note: String
    /// Filename inside the output folder when `status == .done`.
    public var output: String?
    public var processedAt: Date

    public var id: String { pin.id }

    public init(pin: Pin, status: PinStatus, note: String, output: String? = nil, processedAt: Date = .now) {
        self.pin = pin
        self.status = status
        self.note = note
        self.output = output
        self.processedAt = processedAt
    }
}

/// Seen pins + outcomes, persisted as JSON. Lives outside the wallpaper folder.
public struct Library: Sendable {
    public let file: URL
    public private(set) var records: [String: PinRecord] = [:]

    /// Loads `file` if present. An unreadable file is moved aside (`.corrupt`) and the library starts empty.
    public init(file: URL) {
        self.file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: PinRecord].self, from: data) {
            records = decoded
        } else {
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("corrupt"))
        }
    }

    public func isSeen(_ pinID: String) -> Bool { records[pinID]?.status.isSeen ?? false }

    public var recent: [PinRecord] { records.values.sorted { $0.processedAt > $1.processedAt } }

    public mutating func save(_ newRecords: [PinRecord]) throws {
        for record in newRecords { records[record.pin.id] = record }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: file, options: .atomic)
    }

    public mutating func save(_ record: PinRecord) throws { try save([record]) }

    /// Forget pins so the next sync processes them again.
    public mutating func remove(_ pinIDs: [String]) throws {
        for id in pinIDs { records[id] = nil }
        try save([])
    }
}
