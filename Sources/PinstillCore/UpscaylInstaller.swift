import CryptoKit
import Foundation

/// Downloads the official Upscayl DMG from its GitHub releases and copies Upscayl.app into
/// Applications, so setup doesn't send people to upscayl.org, where the Mac DMG sits behind
/// "alternative install methods". Upscayl is notarized, so the installed copy opens normally.
public enum UpscaylInstaller {
    /// electron-builder's update manifest: names the current DMG and its checksum. The DMG's
    /// own name contains the version, so it can't be linked to directly.
    public static let manifestURL = URL(string: "https://github.com/upscayl/upscayl/releases/latest/download/latest-mac.yml")!
    public static let releasesPage = URL(string: "https://github.com/upscayl/upscayl/releases/latest")!

    public struct Download: Sendable, Equatable {
        public let version: String
        public let url: URL
        /// Base64, as the manifest gives it.
        public let sha512: String
        public let size: Int64
    }

    public enum Step: Sendable, Equatable {
        /// 0...1
        case downloading(Double)
        case installing
    }

    public enum InstallError: Error, CustomStringConvertible {
        case noDiskImageInManifest
        case checksumMismatch
        case tool(String)
        case appNotInDiskImage

        public var description: String {
            switch self {
            case .noDiskImageInManifest: "Couldn't find the Mac download in Upscayl's latest release."
            case .checksumMismatch: "The download was incomplete or damaged."
            case .tool(let what): "Installing failed (\(what))."
            case .appNotInDiskImage: "The download didn't contain Upscayl."
            }
        }
    }

    /// Picks the `.dmg` entry out of `latest-mac.yml`. The file is a flat list, so it's read
    /// line by line rather than pulling in a YAML parser.
    public static func parseManifest(_ text: String) -> Download? {
        var version = "", name: String?, sha: String?, size: Int64?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("version:") {
                version = value(of: line)
            } else if line.hasPrefix("- url:") {
                if name != nil, sha != nil { break } // the DMG entry is complete
                let candidate = value(of: String(line.dropFirst(2)))
                name = candidate.hasSuffix(".dmg") ? candidate : nil
                sha = nil
                size = nil
            } else if name != nil, line.hasPrefix("sha512:"), sha == nil {
                sha = value(of: line)
            } else if name != nil, line.hasPrefix("size:"), size == nil {
                size = Int64(value(of: line))
            } else if !raw.hasPrefix(" "), name != nil, sha != nil {
                break // left the files list
            }
        }
        guard let name, let sha,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://github.com/upscayl/upscayl/releases/latest/download/\(encoded)") else { return nil }
        return Download(version: version, url: url, sha512: sha, size: size ?? 0)
    }

    private static func value(of line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }

    public static func latest(session: URLSession = .shared) async throws -> Download {
        let (data, _) = try await session.data(from: manifestURL)
        guard let download = parseManifest(String(decoding: data, as: UTF8.self)) else {
            throw InstallError.noDiskImageInManifest
        }
        return download
    }

    /// Where Upscayl goes: /Applications, or ~/Applications for accounts that can't write there.
    public static var defaultDestination: URL {
        let system = URL(filePath: "/Applications", directoryHint: .isDirectory)
        return FileManager.default.isWritableFile(atPath: system.path(percentEncoded: false))
            ? system : URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
    }

    /// Downloads, verifies and installs Upscayl. Returns the installed app.
    public static func install(into destination: URL = defaultDestination,
                               progress: @escaping @Sendable (Step) -> Void) async throws -> URL {
        let download = try await latest()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "pinstill-upscayl-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress(.downloading(0))
        let image = work.appending(path: "Upscayl.dmg")
        try await fetch(download, to: image, progress: progress)
        guard try sha512(of: image) == download.sha512 else { throw InstallError.checksumMismatch }

        progress(.installing)
        let mount = work.appending(path: "mount")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mount.path(percentEncoded: false), image.path(percentEncoded: false)])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path(percentEncoded: false), "-force"]) }

        let contents = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw InstallError.appNotInDiskImage }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let installed = destination.appending(path: app.lastPathComponent)
        // ditto keeps the signature and extended attributes intact, which a plain copy can lose.
        try run("/usr/bin/ditto", [app.path(percentEncoded: false), installed.path(percentEncoded: false)])
        return installed
    }

    private static func fetch(_ download: Download, to file: URL, progress: @escaping @Sendable (Step) -> Void) async throws {
        let reporter = ProgressReporter { progress(.downloading($0)) }
        let (temporary, response) = try await URLSession.shared.download(from: download.url, delegate: reporter)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    static func sha512(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize()).base64EncodedString()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.tool("\((tool as NSString).lastPathComponent): \(output.suffix(200))")
        }
        return output
    }
}

/// Reports download progress by watching the task's own `progress`: the async
/// `download(from:delegate:)` never calls `didWriteData` on a per-task delegate, so the bar
/// sat at 0% and then jumped straight to installing.
private final class ProgressReporter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}
