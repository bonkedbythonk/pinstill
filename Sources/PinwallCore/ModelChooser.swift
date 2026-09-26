import CoreGraphics
import Vision

/// Which Upscayl model to use for an image.
public enum UpscaleModel: Sendable, Hashable, Codable {
    /// Pick per image from what Vision sees in it.
    case automatic
    /// Always use this model (file name without extension, e.g. "ultrasharp-4x").
    case fixed(String)
}

public enum ImageKind: String, Sendable {
    /// Anime, drawings, paintings, graphic/abstract art: clean lines and flat colour.
    case illustration
    /// Photos: landscapes, cities, people.
    case photo

    public var model: String {
        switch self {
        case .illustration: "digital-art-4x"
        case .photo: "high-fidelity-4x"
        }
    }
}

public enum ModelChooser {
    /// Vision labels that mean "drawn, not photographed". Anime frames typically score
    /// `illustrations`/`art` 0.3–0.8; photos score them near zero.
    static let illustrationLabels: Set<String> = [
        "art", "illustrations", "cartoon", "drawing", "painting", "graffiti", "anime", "comic",
    ]
    static let threshold: Float = 0.1

    public static func classify(_ image: CGImage) -> ImageKind {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let drawn = (request.results ?? []).contains {
            illustrationLabels.contains($0.identifier) && $0.confidence >= threshold
        }
        return drawn ? .illustration : .photo
    }

    /// Model to run, falling back to the first installed one if the preferred model is missing.
    public static func model(for image: CGImage, choice: UpscaleModel, installed: [String]) -> String {
        let preferred: String = switch choice {
        case .automatic: classify(image).model
        case .fixed(let name): name
        }
        return installed.contains(preferred) || installed.isEmpty ? preferred : installed[0]
    }
}
