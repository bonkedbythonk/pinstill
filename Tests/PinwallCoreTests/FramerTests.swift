import Testing
@testable import PinwallCore

private let macbook = PixelSize(width: 3024, height: 1964)

@Test func sameShapeKeepsEverything() {
    #expect(Framer.keptFraction(width: 3024, height: 1964, target: macbook) == 1)
}

@Test func sixteenByTenKeepsMost() {
    // 1920x1200 is slightly wider than 3024x1964 → trims the sides a little.
    let kept = Framer.keptFraction(width: 1920, height: 1200, target: macbook)
    #expect(kept > 0.95 && kept < 1)
}

@Test func phoneWallpaperIsRejected() {
    // 1440x2560 (9:16) keeps ~37%, below the 60% default.
    let kept = Framer.keptFraction(width: 1440, height: 2560, target: macbook)
    #expect(abs(kept - 0.365) < 0.01)
}

@Test func squareSitsAtTheThreshold() {
    let kept = Framer.keptFraction(width: 1000, height: 1000, target: macbook)
    #expect(kept > 0.6 && kept < 0.7)
}

@Test func upscaleFactorRoundsUpToSupportedScale() {
    #expect(Upscaler.scale(forNeeded: 0.5) == nil)
    #expect(Upscaler.scale(forNeeded: 1.0) == nil)
    #expect(Upscaler.scale(forNeeded: 1.6) == 2)
    #expect(Upscaler.scale(forNeeded: 2.5) == 3)
    #expect(Upscaler.scale(forNeeded: 6) == 4)
}
