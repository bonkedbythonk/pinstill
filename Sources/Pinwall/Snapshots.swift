import AppKit
import PinwallCore
import SwiftUI

/// `Pinwall --snapshot <dir>` renders every screen with made-up demo data to PNGs
/// (README screenshots, visual checks) and quits. Touches no real account or files.
@MainActor
enum Snapshots {
    static func render(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = makeSampleWallpapers()

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let model = demoModel(wallpapers: samples)
            await snap(MenuView().environment(model), appearance: appearance, to: folder.appending(path: "menu-\(name).png"))
        }

        let pinned = demoModel(wallpapers: samples)
        pinned.pinnedWallpaper = samples[1].url
        await snap(MenuView().environment(pinned), appearance: .darkAqua, to: folder.appending(path: "menu-pinned.png"))

        let busy = demoModel(wallpapers: samples)
        busy.loadDemo(account: .loggedIn("you"), boards: demoBoards, board: demoBoards[0], wallpapers: samples,
                      skipped: [], activity: .processing(done: 1, total: 3), lastResult: nil)
        await snap(MenuView().environment(busy), appearance: .darkAqua, to: folder.appending(path: "menu-syncing.png"))

        let fresh = AppModel(defaults: UserDefaults(suiteName: "pinwall-snapshot-\(UUID())")!,
                             libraryFile: FileManager.default.temporaryDirectory.appending(path: "pinwall-demo-\(UUID()).json"),
                             demo: true)
        await snap(MenuView().environment(fresh), appearance: .darkAqua, to: folder.appending(path: "menu-welcome.png"))

        for step in [SetupView.Step.welcome, .upscayl, .folder, .board, .done] {
            let model = demoModel(wallpapers: samples)
            await snap(SetupView(onFinish: {}, step: step).environment(model), appearance: .darkAqua,
                       to: folder.appending(path: "setup-\(step).png"))
        }

        for tab in [SettingsView.Tab.general, .pinterest, .upscaling, .about] {
            let model = demoModel(wallpapers: samples)
            await snap(SettingsView(tab: tab).environment(model), appearance: .darkAqua,
                       to: folder.appending(path: "settings-\(tab).png"))
        }
        print("snapshots written to \(folder.path(percentEncoded: false))")
    }

    static let demoBoards = [
        Board(id: "1", name: "Wallpapers", privacy: "secret", path: "/you/wallpapers/", pinCount: 24),
        Board(id: "2", name: "Anime scenery", privacy: "secret", path: "/you/anime-scenery/", pinCount: 58),
        Board(id: "3", name: "Travel", privacy: "public", path: "/you/travel/", pinCount: 12),
    ]

    private static func demoModel(wallpapers: [Wallpaper]) -> AppModel {
        let model = AppModel(defaults: UserDefaults(suiteName: "pinwall-snapshot-\(UUID())")!,
                             libraryFile: FileManager.default.temporaryDirectory.appending(path: "pinwall-demo-\(UUID()).json"),
                             demo: true)
        model.hasCompletedSetup = true
        model.outputFolder = URL(filePath: NSHomeDirectory()).appending(path: "Pictures/Pinwall")
        let skipped = [PinRecord(pin: Pin(id: "s1", title: "", pinURL: URL(string: "https://pinterest.com")!,
                                          imageURL: URL(string: "https://pinterest.com")!, width: 1080, height: 1920,
                                          thumbnailURL: nil),
                                 status: .skippedShape, note: "Wrong shape: cropping would keep 37% of the image")]
        model.loadDemo(account: .loggedIn("you"), boards: demoBoards, board: demoBoards[0], wallpapers: wallpapers,
                       skipped: skipped, activity: .idle, lastResult: "3 added")
        return model
    }

    // MARK: Rendering

    private static func snap(_ view: some View, appearance: NSAppearance.Name, to file: URL) async {
        let root = view
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        // Let async thumbnails and layout settle, then size to fit.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            hosting.setFrameSize(hosting.fittingSize)
            window.setContentSize(hosting.fittingSize)
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    // MARK: Sample images

    /// Colourful abstract "wallpapers" drawn on the fly, so screenshots contain no real pins.
    private static func makeSampleWallpapers() -> [Wallpaper] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pinwall-samples")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let palettes: [[NSColor]] = [
            [.systemIndigo, .systemPink, .systemOrange],
            [.systemTeal, .systemBlue, .systemIndigo],
            [.systemOrange, .systemRed, .systemPurple],
            [.systemMint, .systemTeal, .systemBlue],
            [.systemPurple, .systemIndigo, .black],
            [.systemYellow, .systemOrange, .systemPink],
        ]
        return palettes.enumerated().map { index, colors in
            let url = folder.appending(path: "sample-\(index).png")
            drawSample(colors: colors, seed: index).write(to: url)
            let record: PinRecord? = index == 3
                ? PinRecord(pin: Pin(id: "\(index)", title: "", pinURL: URL(string: "https://pinterest.com")!,
                                     imageURL: url, width: 500, height: 281, thumbnailURL: nil),
                            status: .done, note: "500×281, upscaled 4× + 2× (digital-art-4x) (still low-res)")
                : PinRecord(pin: Pin(id: "\(index)", title: "", pinURL: URL(string: "https://pinterest.com")!,
                                     imageURL: url, width: 1920, height: 1080, thumbnailURL: nil),
                            status: .done, note: "1920×1080, upscaled 2× (digital-art-4x)")
            return Wallpaper(url: url, modified: .now.addingTimeInterval(Double(-index * 600)), record: record)
        }
    }

    private static func drawSample(colors: [NSColor], seed: Int) -> NSBitmapImageRep {
        let size = NSSize(width: 960, height: 600)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: colors)!.draw(in: NSRect(origin: .zero, size: size), angle: Double(20 + seed * 37))
        var rng = SeededRandom(seed: UInt64(seed + 1))
        for _ in 0..<7 {
            let r = CGFloat.random(in: 80...320, using: &rng)
            let rect = NSRect(x: .random(in: -100...size.width, using: &rng), y: .random(in: -100...size.height, using: &rng),
                              width: r, height: r)
            NSColor.white.withAlphaComponent(.random(in: 0.05...0.22, using: &rng)).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        // Rolling hills along the bottom.
        let hills = NSBezierPath()
        hills.move(to: .zero)
        for x in stride(from: 0.0, through: size.width, by: 40) {
            hills.line(to: NSPoint(x: x, y: 140 + 50 * sin(x / 90 + Double(seed))))
        }
        hills.line(to: NSPoint(x: size.width, y: 0))
        hills.close()
        NSColor.black.withAlphaComponent(0.28).setFill()
        hills.fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private extension NSBitmapImageRep {
    func write(to url: URL) {
        try? representation(using: .png, properties: [:])?.write(to: url)
    }
}
