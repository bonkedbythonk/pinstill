import Foundation
import ImageIO

public struct PipelineOptions: Sendable {
    /// Pixel size to render for (largest connected screen).
    public var target: PixelSize
    /// Finished wallpapers land here, e.g. the folder macOS rotates. Nothing else is ever written here.
    public var outputFolder: URL
    /// Scratch space for downloads and intermediates.
    public var workFolder: URL
    public var upscaler: Upscaler?
    public var model: UpscaleModel = .automatic
    /// Skip when cropping to the screen's shape would keep less than this share of the image.
    public var minKeep: Double = 0.6
    /// Upscayl passes allowed per image (each up to 4×), for very small originals.
    public var maxUpscalePasses = 2

    public init(target: PixelSize, outputFolder: URL, workFolder: URL, upscaler: Upscaler?) {
        self.target = target
        self.outputFolder = outputFolder
        self.workFolder = workFolder
        self.upscaler = upscaler
    }

    public static func outputName(for pinID: String) -> String { "pinwall-\(pinID).jpg" }
}

public struct PipelineResult: Sendable {
    public let record: PinRecord
    public let timings: [(String, Duration)]
}

public enum Pipeline {
    /// Download → crop to screen shape → upscale if too small → exact-size JPEG in the output folder.
    /// Blocking work (Vision, Core Image, upscayl-bin); call from a background task.
    public static func process(_ pin: Pin, options: PipelineOptions,
                               log: (String) -> Void = { _ in }) async throws -> PipelineResult {
        var timer = Timer()
        func skipped(_ kept: Double) -> PipelineResult {
            PipelineResult(record: PinRecord(pin: pin, status: .skippedShape, note: shapeNote(kept)),
                           timings: timer.timings)
        }

        // Size known up front (Pinterest API) → skip tall images without downloading them.
        if let w = pin.width, let h = pin.height {
            let kept = Framer.keptFraction(width: w, height: h, target: options.target)
            if kept < options.minKeep { return skipped(kept) }
        }

        let work = options.workFolder.appending(path: pin.id)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let original = try await timer.time("download") {
            try await ImageFetcher.download(pin.imageURL, to: work, name: "original")
        }
        switch try await fit(original, work: work, options: options, timer: &timer, log: log) {
        case .skip(let kept):
            return skipped(kept)
        case .rendered(let rendered, let note):
            let name = PipelineOptions.outputName(for: pin.id)
            try place(rendered, at: options.outputFolder.appending(path: name))
            return PipelineResult(record: PinRecord(pin: pin, status: .done, note: note, output: name),
                                  timings: timer.timings)
        }
    }

    enum FitResult {
        case skip(keptFraction: Double)
        /// Finished exact-size JPEG in the work folder.
        case rendered(URL, note: String)
    }

    /// Crop `original` to the screen's shape, upscale as needed, render an exact-size JPEG into `work`.
    static func fit(_ original: URL, work: URL, options: PipelineOptions, timer: inout Timer,
                    log: (String) -> Void) async throws -> FitResult {
        let image = try Framer.loadImage(original)
        log("original \(image.width)x\(image.height)")

        let decision = await timer.time("frame") { Framer.decide(image, target: options.target, minKeep: options.minKeep) }
        let rect: CGRect, kept: Double
        switch decision {
        case .crop(let r, let k): (rect, kept) = (r, k)
        case .skip(let k): return .skip(keptFraction: k)
        }
        log(String(format: "crop %dx%d keeps %.0f%%", Int(rect.width), Int(rect.height), kept * 100))

        var source = work.appending(path: "cropped.png")
        guard let croppedImage = image.cropping(to: rect) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Crop failed"])
        }
        try Renderer.writePNG(croppedImage, to: source)

        let target = options.target
        var needed = max(Double(target.width) / rect.width, Double(target.height) / rect.height)
        var note = "\(image.width)×\(image.height)"
        if needed > 1, options.upscaler == nil {
            note += ", resized (Upscayl not installed)"
        } else if let upscaler = options.upscaler, needed > 1 {
            let model = ModelChooser.model(for: croppedImage, choice: options.model, installed: upscaler.installedModels)
            log("model \(model)")
            // Each Upscayl pass is at most 4×; tiny originals get a second pass.
            var passes: [Int] = []
            while let scale = Upscaler.scale(forNeeded: needed), passes.count < options.maxUpscalePasses {
                let output = work.appending(path: "upscaled-\(passes.count).png")
                try await timer.time("upscale \(scale)x") {
                    try upscaler.upscale(source, to: output, scale: scale, model: model)
                }
                source = output
                passes.append(scale)
                needed /= Double(scale)
            }
            if !passes.isEmpty {
                note += ", upscaled " + passes.map { "\($0)×" }.joined(separator: " + ") + " (\(model))"
            }
            if needed > 1.05 { note += " (still low-res)" }
        }

        let rendered = work.appending(path: "rendered.jpg")
        try await timer.time("render") { try Renderer.render(source, size: target, to: rendered) }
        return .rendered(rendered, note: note)
    }

    /// Moves a finished file into place in one step: the rotation folder never sees partial files.
    static func place(_ file: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }

    static func shapeNote(_ kept: Double) -> String {
        String(format: "Wrong shape: cropping would keep %.0f%% of the image", kept * 100)
    }
}

/// Collects labelled durations for the spike's timing output.
struct Timer {
    private let clock = ContinuousClock()
    private(set) var timings: [(String, Duration)] = []

    mutating func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let start = clock.now
        let value = try await body()
        timings.append((label, clock.now - start))
        return value
    }
}
