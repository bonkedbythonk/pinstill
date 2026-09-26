import AppKit
import Foundation

/// Runs the `upscayl-bin` CLI that ships inside Upscayl.app (github.com/upscayl/upscayl).
/// Upscayl is AGPL and installed separately; Pinwall never bundles it.
public struct Upscaler: Sendable {
    public let app: URL
    public let binary: URL
    public let models: URL
    public let version: String?

    public static let bundleID = "org.upscayl.Upscayl"
    public static let downloadURL = URL(string: "https://upscayl.org")!

    /// Finds Upscayl wherever it's installed. Returns nil when it isn't.
    @MainActor
    public static func locate() -> Upscaler? {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? URL(filePath: "/Applications/Upscayl.app")
        return at(app)
    }

    public static func at(_ app: URL) -> Upscaler? {
        let resources = app.appending(path: "Contents/Resources")
        let binary = resources.appending(path: "bin/upscayl-bin")
        guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) else { return nil }
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        return Upscaler(app: app, binary: binary, models: resources.appending(path: "models"), version: version)
    }

    /// Installed model names (e.g. "digital-art-4x"), sorted.
    public var installedModels: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: models.path(percentEncoded: false))) ?? []
        return Set(files.filter { $0.hasSuffix(".param") }.map { String($0.dropLast(6)) }).sorted()
    }

    /// Upscayl models are all 4x; `-s 2|3|4` picks output scale.
    public static func scale(forNeeded factor: Double) -> Int? {
        switch factor {
        case ...1: nil
        case ...2: 2
        case ...3: 3
        default: 4
        }
    }

    public func upscale(_ input: URL, to output: URL, scale: Int, model: String) throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-i", input.path(percentEncoded: false), "-o", output.path(percentEncoded: false),
            "-m", models.path(percentEncoded: false), "-n", model,
            "-s", String(scale), "-f", "png",
        ]
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        let data = log.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) else {
            throw UpscalerError.failed(status: process.terminationStatus, log: String(decoding: data, as: UTF8.self))
        }
    }
}

public enum UpscalerError: Error, CustomStringConvertible {
    case failed(status: Int32, log: String)
    public var description: String {
        switch self {
        case .failed(let status, let log): "upscayl-bin exited \(status): \(log.suffix(400))"
        }
    }
}
