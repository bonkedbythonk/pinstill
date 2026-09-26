import Foundation

/// Pinstill was called Pinwall up to 0.1.0 (bundle id io.github.bonkedbythonk.pinwall).
/// The new bundle id starts with empty settings, an empty library and no Pinterest login,
/// so the first launch brings those over. Runs before anything reads settings or creates
/// the web view; does nothing once the new app has settings of its own.
enum Migration {
    static let oldBundleID = "io.github.bonkedbythonk.pinwall"

    static func fromPinwall() {
        guard let newID = Bundle.main.bundleIdentifier, newID != oldBundleID else { return }
        let defaults = UserDefaults.standard
        guard defaults.persistentDomain(forName: newID)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty else { return }

        defaults.setPersistentDomain(old, forName: newID)

        let fm = FileManager.default
        let library = URL.libraryDirectory
        let moves: [(URL, URL)] = [
            // Seen pins and their outcomes; without it every pin would be processed again.
            (library.appending(path: "Application Support/Pinwall"), library.appending(path: "Application Support/Pinstill")),
            // WebKit keeps cookies per bundle id; copying them keeps the Pinterest login.
            (library.appending(path: "WebKit/\(oldBundleID)"), library.appending(path: "WebKit/\(newID)")),
        ]
        for (from, to) in moves where fm.fileExists(atPath: from.path(percentEncoded: false))
            && !fm.fileExists(atPath: to.path(percentEncoded: false)) {
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: from, to: to)
        }
    }
}
