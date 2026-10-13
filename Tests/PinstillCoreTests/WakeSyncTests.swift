import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import PinstillCore

@Test func wakeSyncWaitsForTheGap() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(WakeSync.isDue(lastSync: nil, now: now))
    #expect(!WakeSync.isDue(lastSync: now.addingTimeInterval(-600), now: now))
    #expect(WakeSync.isDue(lastSync: now.addingTimeInterval(-3600), now: now))
}

@Test func biggerDisplayHasMorePixels() {
    let macbook = PixelSize(width: 3024, height: 1964)
    let studio = PixelSize(width: 5120, height: 2880)
    #expect(studio.hasMorePixels(than: macbook))
    #expect(!macbook.hasMorePixels(than: studio))
    #expect(!macbook.hasMorePixels(than: macbook))
}

@Test func minKeepZeroCropsATallImageInsteadOfSkippingIt() throws {
    let macbook = PixelSize(width: 3024, height: 1964)
    let context = try #require(CGContext(data: nil, width: 1080, height: 1920, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    if case .crop = Framer.decide(image, target: macbook, minKeep: 0.6) { Issue.record("should skip by default") }
    guard case .crop(let rect, _) = Framer.decide(image, target: macbook, minKeep: 0) else {
        Issue.record("should crop")
        return
    }
    #expect(rect.width == 1080)
}

@Test func aTallPinCroppedAnywayIsMarkedSoRedoingItCropsAgain() async throws {
    let work = FileManager.default.temporaryDirectory.appending(path: "pinstill-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let tall = work.appending(path: "tall.png")
    let context = try #require(CGContext(data: nil, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let destination = try #require(CGImageDestinationCreateWithURL(tall as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    var options = PipelineOptions(target: PixelSize(width: 300, height: 200), outputFolder: work, workFolder: work, upscaler: nil)
    var timer = Timer()
    guard case .skip = try await Pipeline.fit(tall, work: work, options: options, timer: &timer, log: { _ in }) else {
        Issue.record("should skip by default"); return
    }
    options.minKeep = 0
    guard case .rendered(_, let note) = try await Pipeline.fit(tall, work: work, options: options, timer: &timer, log: { _ in }) else {
        Issue.record("should render"); return
    }
    #expect(note.contains(PipelineOptions.croppedAnywayMarker))
}
