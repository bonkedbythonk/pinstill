import Foundation

/// Finds out whether a newer Pinstill release exists on GitHub.
public enum UpdateCheck {
    public static let releasesPage = URL(string: "https://github.com/bonkedbythonk/pinstill/releases/latest")!

    public struct Release: Sendable, Equatable {
        public let version: String
        public let page: URL
    }

    /// The latest release's version, read from where `/releases/latest` redirects
    /// (`…/releases/tag/v0.2.0`). The web redirect has no rate limit, unlike the API's 60
    /// anonymous requests an hour shared by everyone behind the same IP.
    public static func latest(session: URLSession = .shared) async throws -> Release? {
        var request = URLRequest(url: releasesPage)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, final.pathComponents.dropLast().last == "tag" else { return nil }
        let tag = final.lastPathComponent
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: final)
    }

    /// "0.10.0" is newer than "0.9.2"; missing parts count as 0. Non-numeric parts
    /// (a "dev" build) never compare as older, so dev builds don't nag.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let pieces = v.split(separator: ".").map { Int($0) }
            return pieces.contains(nil) || pieces.isEmpty ? nil : pieces.compactMap { $0 }
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
