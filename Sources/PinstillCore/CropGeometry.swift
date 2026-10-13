import CoreGraphics

/// Crop rectangles for a screen-shaped crop box, all normalized: 0 to 1 of the image, origin top-left
/// (the same orientation as `CGImage.cropping`). Normalized survives the downloader falling back
/// to a smaller variant of the image.
public enum CropGeometry {
    /// Size of the largest crop with `aspect` that fits the image.
    public static func fullSize(imageWidth: Int, imageHeight: Int, aspect: Double) -> CGSize {
        let w = Double(imageWidth), h = Double(imageHeight)
        let (cw, ch) = Framer.cropSize(width: w, height: h, aspect: aspect)
        return CGSize(width: cw / w, height: ch / h)
    }

    /// The crop at `zoom` (1 = the largest crop, smaller = closer in) centered on `center`, nudged to stay inside the image.
    public static func rect(imageWidth: Int, imageHeight: Int, aspect: Double, zoom: Double, center: CGPoint) -> CGRect {
        let full = fullSize(imageWidth: imageWidth, imageHeight: imageHeight, aspect: aspect)
        let z = min(max(zoom, minimumZoom), 1)
        let size = CGSize(width: full.width * z, height: full.height * z)
        return CGRect(x: min(max(center.x - size.width / 2, 0), 1 - size.width),
                      y: min(max(center.y - size.height / 2, 0), 1 - size.height),
                      width: size.width, height: size.height)
    }

    public static let minimumZoom = 0.15

    public static func zoom(of rect: CGRect, imageWidth: Int, imageHeight: Int, aspect: Double) -> Double {
        let full = fullSize(imageWidth: imageWidth, imageHeight: imageHeight, aspect: aspect)
        return min(max(rect.width / full.width, minimumZoom), 1)
    }

    /// A saved crop made for another screen shape (a different display is the largest now): the
    /// biggest box of the current shape inside it, around the same center. Unchanged when the shape still fits.
    public static func refit(_ rect: CGRect, imageWidth: Int, imageHeight: Int, aspect: Double) -> CGRect {
        let w = Double(imageWidth), h = Double(imageHeight)
        let (pw, ph) = (rect.width * w, rect.height * h)
        guard abs(pw / ph - aspect) / aspect > 0.01 else { return rect }
        let (cw, ch) = Framer.cropSize(width: pw, height: ph, aspect: aspect)
        return CGRect(x: rect.midX - cw / w / 2, y: rect.midY - ch / h / 2, width: cw / w, height: ch / h)
    }
}
