import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PinwallCore

private func writeImage(_ url: URL, width: Int, height: Int) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "pinwall-tests-\(UUID().uuidString)/Wallpapers")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let target = PixelSize(width: 300, height: 200)

@Test func candidatesSkipExactSizeAndPinwallOutputs() throws {
    let folder = try tempFolder()
    try writeImage(folder.appending(path: "exact.png"), width: 300, height: 200)
    try writeImage(folder.appending(path: "big.png"), width: 480, height: 270)
    try writeImage(folder.appending(path: "pinwall-123.png"), width: 480, height: 270)
    try Data("not an image".utf8).write(to: folder.appending(path: "notes.txt"))

    let names = LocalFitter.candidates(in: folder, target: target).map(\.lastPathComponent)
    #expect(names == ["big.png"])
}

@Test func fitMovesOriginalAsideAndWritesExactSize() async throws {
    let folder = try tempFolder()
    let file = folder.appending(path: "wide.png")
    try writeImage(file, width: 480, height: 270)
    let options = PipelineOptions(target: target, outputFolder: folder,
                                  workFolder: folder.deletingLastPathComponent().appending(path: "work"),
                                  upscaler: nil)

    guard case .fitted = try await LocalFitter.fit(file, options: options) else {
        Issue.record("expected fitted"); return
    }
    let originals = LocalFitter.originalsFolder(for: folder)
    #expect(FileManager.default.fileExists(atPath: originals.appending(path: "wide.png").path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    #expect(LocalFitter.pixelSize(of: folder.appending(path: "wide.jpg")) == target)
    // Now exact size → no longer a candidate.
    #expect(LocalFitter.candidates(in: folder, target: target).isEmpty)
}

@Test func tallImageIsLeftAlone() async throws {
    let folder = try tempFolder()
    let file = folder.appending(path: "phone.png")
    try writeImage(file, width: 180, height: 320)
    let options = PipelineOptions(target: target, outputFolder: folder,
                                  workFolder: folder.deletingLastPathComponent().appending(path: "work"),
                                  upscaler: nil)

    guard case .skipped = try await LocalFitter.fit(file, options: options) else {
        Issue.record("expected skipped"); return
    }
    #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
}
