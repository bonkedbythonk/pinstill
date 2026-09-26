import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct PixelSize: Sendable, Hashable, Codable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var aspect: Double { Double(width) / Double(height) }
    public var description: String { "\(width)x\(height)" }
}

public enum FrameDecision: Sendable {
    /// Crop rect in image pixel coordinates (origin top-left).
    case crop(CGRect, keptFraction: Double)
    case skip(keptFraction: Double)
}

public enum Framer {
    public static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        return image
    }

    /// Largest rect of `target` aspect that fits the image, centered on the salient region.
    /// Skips when the crop would keep less than `minKeep` of the image area.
    public static func decide(_ image: CGImage, target: PixelSize, minKeep: Double) -> FrameDecision {
        let w = Double(image.width), h = Double(image.height)
        let (cw, ch) = cropSize(width: w, height: h, aspect: target.aspect)
        let kept = keptFraction(width: image.width, height: image.height, target: target)
        guard kept >= minKeep else { return .skip(keptFraction: kept) }

        let focus = salientCenter(image) ?? CGPoint(x: 0.5, y: 0.5)
        let x = min(max(focus.x * w - cw / 2, 0), w - cw)
        let y = min(max(focus.y * h - ch / 2, 0), h - ch)
        return .crop(CGRect(x: x, y: y, width: cw, height: ch).integral, keptFraction: kept)
    }

    /// Share of the image area left after cropping to `target`'s aspect ratio (1 = no crop).
    public static func keptFraction(width: Int, height: Int, target: PixelSize) -> Double {
        let w = Double(width), h = Double(height)
        let (cw, ch) = cropSize(width: w, height: h, aspect: target.aspect)
        return (cw * ch) / (w * h)
    }

    static func cropSize(width w: Double, height h: Double, aspect: Double) -> (Double, Double) {
        w / h > aspect ? (h * aspect, h) : (w, w / aspect)
    }

    /// Center of the union of salient objects, normalized, origin top-left.
    static func salientCenter(_ image: CGImage) -> CGPoint? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let objects = request.results?.first?.salientObjects, !objects.isEmpty else { return nil }
        let box = objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: box.midX, y: 1 - box.midY) // Vision is bottom-left origin
    }
}
