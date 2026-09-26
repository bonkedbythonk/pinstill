import Foundation
import ImageIO

/// Fits images the user put in the wallpaper folder themselves: crop to screen shape, upscale if
/// needed, exact screen size. The original is moved (never deleted) to a sibling "Originals" folder.
public enum LocalFitter {
    public enum Outcome: Sendable {
        case fitted(note: String)
        case skipped(note: String)
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"]

    /// `~/Documents/Pinwall` → `~/Documents/Pinwall Originals` (outside the rotation folder).
    public static func originalsFolder(for folder: URL) -> URL {
        folder.deletingLastPathComponent()
            .appending(path: "\(folder.lastPathComponent) Originals", directoryHint: .isDirectory)
    }

    /// The user's own images in `folder` that aren't already exactly `target` size.
    /// Pinwall's own `pinwall-*.jpg` outputs are left alone.
    public static func candidates(in folder: URL, target: PixelSize) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("pinwall-") }
            .filter { pixelSize(of: $0).map { $0 != target } ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads dimensions from the file header without decoding the image.
    public static func pixelSize(of file: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return PixelSize(width: w, height: h)
    }

    /// Blocking (Vision, Core Image, upscayl-bin); call from a background task.
    public static func fit(_ file: URL, options: PipelineOptions) async throws -> Outcome {
        if let size = pixelSize(of: file) {
            let kept = Framer.keptFraction(width: size.width, height: size.height, target: options.target)
            if kept < options.minKeep { return .skipped(note: Pipeline.shapeNote(kept)) }
        }

        let work = options.workFolder.appending(path: "local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var timer = Timer()
        switch try await Pipeline.fit(file, work: work, options: options, timer: &timer, log: { _ in }) {
        case .skip(let kept):
            return .skipped(note: Pipeline.shapeNote(kept))
        case .rendered(let rendered, let note):
            let folder = file.deletingLastPathComponent()
            let originals = originalsFolder(for: folder)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: uniqueURL(originals.appending(path: file.lastPathComponent)))
            let stem = file.deletingPathExtension().lastPathComponent
            try Pipeline.place(rendered, at: uniqueURL(folder.appending(path: "\(stem).jpg")))
            return .fitted(note: note)
        }
    }

    /// `name.png` → `name 2.png` … if taken.
    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for n in 2... {
            let candidate = folder.appending(path: "\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        fatalError("unreachable")
    }
}
