import Foundation

/// How often macOS switches wallpapers when it rotates through a folder: the options of the
/// Shuffle menu in System Settings, Wallpaper. Raw values are the ids macOS stores (read from
/// the store on macOS 27 by picking each option in System Settings).
public enum ShuffleInterval: String, CaseIterable, Sendable, Codable {
    case every5Seconds = "shuffle_every_5_seconds"
    case every1Minute = "shuffle_every_1_minute"
    case every5Minutes = "shuffle_every_5_minutes"
    case every15Minutes = "shuffle_every_15_minutes"
    case every30Minutes = "shuffle_every_30_minutes"
    case every1Hour = "shuffle_every_1_hour"
    case every1Day = "shuffle_every_1_day"
    case onLogin = "shuffle_on_login"
    case onWakeup = "shuffle_on_wakeup"

    public var label: String {
        switch self {
        case .every5Seconds: "Every 5 seconds"
        case .every1Minute: "Every minute"
        case .every5Minutes: "Every 5 minutes"
        case .every15Minutes: "Every 15 minutes"
        case .every30Minutes: "Every 30 minutes"
        case .every1Hour: "Every hour"
        case .every1Day: "Every day"
        case .onLogin: "When I log in"
        case .onWakeup: "When the Mac wakes"
        }
    }
}

/// Reads and changes macOS's own folder-rotation settings (interval, random order).
///
/// There is no API for these: `NSWorkspace.setDesktopImageURL` with a folder turns rotation on
/// but resets the interval to 30 minutes. So this edits the wallpaper store directly,
/// `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, then restarts
/// WallpaperAgent so it rereads it. The format is undocumented; if a macOS update changes it,
/// `apply` finds no matching entries and returns 0 rather than writing anything.
public enum MacRotation {
    public static let store = URL.libraryDirectory
        .appending(path: "Application Support/com.apple.wallpaper/Store/Index.plist")

    public struct Settings: Sendable, Equatable {
        public var interval: ShuffleInterval?
        public var randomly: Bool?
    }

    /// The settings of the first desktop that rotates through `folder`, if any.
    public static func current(for folder: URL, store: URL = store) -> Settings? {
        guard let root = load(store) else { return nil }
        var found: Settings?
        visitRotations(of: folder, in: root) { options in
            if found == nil { found = settings(from: options) }
            return nil
        }
        return found
    }

    /// Sets interval and/or random order on every desktop that rotates through `folder`.
    /// Returns how many desktop entries changed. Call `restartAgent()` afterwards.
    @discardableResult
    public static func apply(folder: URL, interval: ShuffleInterval?, randomly: Bool?, store: URL = store) throws -> Int {
        guard var root = load(store) else { return 0 }
        var changed = 0
        root = visitRotations(of: folder, in: root) { options in
            var options = options
            var values = options["values"] as? [String: Any] ?? [:]
            if let interval { values["shuffleFrequency"] = ["picker": ["_0": ["id": interval.rawValue]]] }
            if let randomly { values["shuffleRandomly"] = ["toggle": ["_0": ["isOn": randomly]]] }
            options["values"] = values
            changed += 1
            return options
        }
        guard changed > 0 else { return 0 }
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: store, options: .atomic)
        return changed
    }

    /// WallpaperAgent only reads the store at launch; launchd starts it again right away.
    public static func restartAgent() {
        let kill = Process()
        kill.executableURL = URL(filePath: "/usr/bin/killall")
        kill.arguments = ["WallpaperAgent"]
        try? kill.run()
        kill.waitUntilExit()
    }

    // MARK: Store walking

    private static func load(_ store: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: store) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func settings(from options: [String: Any]) -> Settings {
        let values = options["values"] as? [String: Any] ?? [:]
        let id = ((values["shuffleFrequency"] as? [String: Any])?["picker"] as? [String: Any])
            .flatMap { ($0["_0"] as? [String: Any])?["id"] as? String }
        let random = ((values["shuffleRandomly"] as? [String: Any])?["toggle"] as? [String: Any])
            .flatMap { ($0["_0"] as? [String: Any])?["isOn"] as? Bool }
        return Settings(interval: id.flatMap(ShuffleInterval.init(rawValue:)), randomly: random)
    }

    /// Finds every `Content` block (one per desktop / display / Space) whose choice is an image
    /// folder pointing at `folder`, and lets `transform` replace its decoded option values.
    @discardableResult
    static func visitRotations(of folder: URL, in node: [String: Any],
                               transform: ([String: Any]) -> [String: Any]?) -> [String: Any] {
        var node = node
        if let choices = node["Choices"] as? [[String: Any]], let encoded = node["EncodedOptionValues"] as? Data,
           choices.contains(where: { isFolderChoice($0, folder: folder) }),
           let options = try? PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any],
           let replaced = transform(options),
           let data = try? PropertyListSerialization.data(fromPropertyList: replaced, format: .binary, options: 0) {
            node["EncodedOptionValues"] = data
        }
        for (key, value) in node {
            if let dict = value as? [String: Any] {
                node[key] = visitRotations(of: folder, in: dict, transform: transform)
            } else if let array = value as? [Any] {
                node[key] = array.map { ($0 as? [String: Any]).map { visitRotations(of: folder, in: $0, transform: transform) } ?? $0 }
            }
        }
        return node
    }

    private static func isFolderChoice(_ choice: [String: Any], folder: URL) -> Bool {
        guard let data = choice["Configuration"] as? Data, !data.isEmpty,
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              config["type"] as? String == "imageFolder",
              let relative = (config["url"] as? [String: Any])?["relative"] as? String,
              let url = URL(string: relative) else { return false }
        return url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            == folder.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
