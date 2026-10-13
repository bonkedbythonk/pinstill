import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PinstillCore

private let aspect = 1.5 // 3:2

@Test func fullCropOfAWideImageKeepsItsHeight() {
    let size = CropGeometry.fullSize(imageWidth: 3000, imageHeight: 1000, aspect: aspect)
    #expect(abs(size.height - 1) < 1e-9)
    #expect(abs(size.width - 0.5) < 1e-9) // 1500 of 3000 wide
}

@Test func cropStaysInsideTheImage() {
    let rect = CropGeometry.rect(imageWidth: 3000, imageHeight: 1000, aspect: aspect, zoom: 0.5, center: CGPoint(x: 0.99, y: 0.01))
    #expect(rect.minX >= 0 && rect.maxX <= 1.0000001)
    #expect(rect.minY >= 0 && rect.maxY <= 1.0000001)
    #expect(abs(rect.width * 3000 / (rect.height * 1000) - aspect) < 1e-6)
}

@Test func zoomRoundTrips() {
    let rect = CropGeometry.rect(imageWidth: 2000, imageHeight: 1200, aspect: aspect, zoom: 0.6, center: CGPoint(x: 0.5, y: 0.5))
    #expect(abs(CropGeometry.zoom(of: rect, imageWidth: 2000, imageHeight: 1200, aspect: aspect) - 0.6) < 1e-9)
}

@Test func refitKeepsTheCenterAndFixesTheShape() {
    let old = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.6) // not 3:2 on a 2000x1200 image
    let fitted = CropGeometry.refit(old, imageWidth: 2000, imageHeight: 1200, aspect: aspect)
    #expect(abs(fitted.midX - old.midX) < 1e-9 && abs(fitted.midY - old.midY) < 1e-9)
    #expect(abs(fitted.width * 2000 / (fitted.height * 1200) - aspect) < 1e-6)
    #expect(fitted.width <= old.width + 1e-9 && fitted.height <= old.height + 1e-9)
    // Already the right shape: unchanged.
    let same = CropGeometry.rect(imageWidth: 2000, imageHeight: 1200, aspect: aspect, zoom: 0.5, center: CGPoint(x: 0.5, y: 0.5))
    #expect(CropGeometry.refit(same, imageWidth: 2000, imageHeight: 1200, aspect: aspect) == same)
}

@Test func libraryFilesWrittenBeforeCropsExistStillLoad() throws {
    let json = """
    {"1": {"pin": {"id": "1", "title": "", "pinURL": "https://pinterest.com/pin/1/", "imageURL": "https://i.pinimg.com/a.jpg",
                   "width": 10, "height": 5},
           "status": "done", "note": "n", "output": "pinstill-1.jpg", "processedAt": "2026-01-01T00:00:00Z"}}
    """
    let file = FileManager.default.temporaryDirectory.appending(path: "pinstill-\(UUID().uuidString)/library.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)
    let library = Library(file: file)
    #expect(library.records["1"]?.status == .done)
    #expect(library.records["1"]?.crop == nil)
}

@Test func aHandPickedCropIsUsedAndNotSkippedForItsShape() async throws {
    let work = FileManager.default.temporaryDirectory.appending(path: "pinstill-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    // 200x400 portrait: skipped without a hand-picked crop.
    let file = work.appending(path: "tall.png")
    let context = try #require(CGContext(data: nil, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    let options = PipelineOptions(target: PixelSize(width: 300, height: 200), outputFolder: work, workFolder: work, upscaler: nil)
    var timer = Timer()
    guard case .skip = try await Pipeline.fit(file, work: work, options: options, timer: &timer, log: { _ in }) else {
        Issue.record("should skip without a crop"); return
    }
    let crop = CropGeometry.rect(imageWidth: 200, imageHeight: 400, aspect: 1.5, zoom: 0.5, center: CGPoint(x: 0.5, y: 0.8))
    guard case .rendered(let output, let note) = try await Pipeline.fit(file, work: work, options: options, crop: crop,
                                                                       timer: &timer, log: { _ in }) else {
        Issue.record("should render"); return
    }
    #expect(LocalFitter.pixelSize(of: output) == options.target)
    #expect(!note.contains(PipelineOptions.croppedAnywayMarker))
}
