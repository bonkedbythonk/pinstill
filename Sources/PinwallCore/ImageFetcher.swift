import Foundation

public enum ImageFetcher {
    /// `i.pinimg.com/236x/ab/cd/ef/hash.jpg` → candidates from largest to smallest.
    public static func candidates(for imageURL: URL) -> [URL] {
        let s = imageURL.absoluteString
        guard s.contains("pinimg.com/") else { return [imageURL] }
        let sizes = ["originals", "1200x", "736x"]
        let rewritten = sizes.compactMap { size in
            URL(string: s.replacing(/pinimg\.com\/[^\/]+\//, with: "pinimg.com/\(size)/"))
        }
        return rewritten + [imageURL]
    }

    /// Downloads the largest available variant to `directory`, returns file URL.
    public static func download(_ imageURL: URL, to directory: URL, name: String,
                                session: URLSession = .shared) async throws -> URL {
        var lastError: Error = URLError(.fileDoesNotExist)
        for candidate in candidates(for: imageURL) {
            do {
                let (tmp, response) = try await session.download(from: candidate)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let ext = candidate.pathExtension.isEmpty ? "jpg" : candidate.pathExtension
                let dest = directory.appending(path: "\(name).\(ext)")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return dest
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
