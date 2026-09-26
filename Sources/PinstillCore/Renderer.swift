import CoreImage
import Foundation

public enum Renderer {
    // One context per call rather than a shared static: SDKs before macOS 26 don't mark
    // CIContext Sendable, which failed the Xcode 16 build. Creating one costs far less than
    // the upscale that runs next to it.
    private static var context: CIContext { CIContext() }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try context.writePNGRepresentation(of: CIImage(cgImage: image), to: url,
                                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Scales to cover `size` (Lanczos), center-crops the rounding remainder, writes JPEG.
    public static func render(_ input: URL, size: PixelSize, to output: URL, quality: Double = 0.95) throws {
        guard let image = CIImage(contentsOf: input) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: input.path(percentEncoded: false)])
        }
        let scale = max(Double(size.width) / image.extent.width, Double(size.height) / image.extent.height)
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        let scaled = filter.outputImage!
        let x = scaled.extent.minX + (scaled.extent.width - Double(size.width)) / 2
        let y = scaled.extent.minY + (scaled.extent.height - Double(size.height)) / 2
        let cropped = scaled.cropped(to: CGRect(x: x.rounded(), y: y.rounded(),
                                                width: Double(size.width), height: Double(size.height)))
        try context.writeJPEGRepresentation(
            of: cropped, to: output, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }
}
