// Draws the Pinwall app icon and writes Icon.icns + docs/icon.png.
// Usage: swift Scripts/make_icon.swift   (from the repo root)
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024 // design on a 1024 grid
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }

    // The wall: flat warm plaster on the standard 824pt macOS tile.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    rgb(236, 229, 218).setFill()
    tilePath.fill()

    // One print, turned a little, hanging from the pin.
    ctx.saveGState()
    tilePath.addClip()
    ctx.translateBy(x: 512 * s, y: 470 * s)
    ctx.rotate(by: -5 * .pi / 180)
    let w = 600 * s, h = 420 * s, mat = 30 * s
    let print = NSRect(x: -w / 2, y: -h / 2, width: w, height: h)
    // A hard offset shadow, like paper standing off the wall, instead of a soft blur.
    rgb(214, 205, 192).setFill()
    NSBezierPath(rect: print.offsetBy(dx: 16 * s, dy: -16 * s)).fill()
    rgb(252, 250, 246).setFill()
    NSBezierPath(rect: print).fill()

    let photo = print.insetBy(dx: mat, dy: mat)
    NSBezierPath(rect: photo).addClip()
    rgb(242, 186, 150).setFill()                      // evening sky
    NSBezierPath(rect: photo).fill()
    rgb(250, 226, 190).setFill()                      // low sun
    NSBezierPath(ovalIn: NSRect(x: photo.midX + 60 * s, y: photo.minY + 150 * s, width: 110 * s, height: 110 * s)).fill()
    let far = NSBezierPath()                          // far hills
    far.move(to: NSPoint(x: photo.minX, y: photo.minY + 140 * s))
    far.line(to: NSPoint(x: photo.minX + 170 * s, y: photo.minY + 250 * s))
    far.line(to: NSPoint(x: photo.minX + 300 * s, y: photo.minY + 160 * s))
    far.line(to: NSPoint(x: photo.minX + 400 * s, y: photo.minY + 215 * s))
    far.line(to: NSPoint(x: photo.maxX, y: photo.minY + 120 * s))
    far.line(to: NSPoint(x: photo.maxX, y: photo.minY))
    far.line(to: NSPoint(x: photo.minX, y: photo.minY))
    far.close()
    rgb(125, 104, 140).setFill()
    far.fill()
    let near = NSBezierPath()                         // near hill
    near.move(to: NSPoint(x: photo.minX, y: photo.minY + 60 * s))
    near.curve(to: NSPoint(x: photo.maxX, y: photo.minY + 95 * s),
               controlPoint1: NSPoint(x: photo.minX + 200 * s, y: photo.minY + 170 * s),
               controlPoint2: NSPoint(x: photo.minX + 330 * s, y: photo.minY + 10 * s))
    near.line(to: NSPoint(x: photo.maxX, y: photo.minY))
    near.line(to: NSPoint(x: photo.minX, y: photo.minY))
    near.close()
    rgb(68, 58, 82).setFill()
    near.fill()
    ctx.restoreGState()

    // The pin: Pinwall's one red thing.
    let head = NSRect(x: 470 * s, y: 640 * s, width: 104 * s, height: 104 * s)
    rgb(178, 52, 44).setFill()                        // flat under-edge
    NSBezierPath(ovalIn: head.offsetBy(dx: 0, dy: -8 * s)).fill()
    rgb(217, 69, 59).setFill()
    NSBezierPath(ovalIn: head).fill()
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: head.minX + 24 * s, y: head.maxY - 44 * s, width: 28 * s, height: 18 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appending(path: "Pinwall.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}
let docs = root.appending(path: "docs")
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try drawIcon(size: 512).representation(using: .png, properties: [:])!.write(to: docs.appending(path: "icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path(percentEncoded: false), "-o", root.appending(path: "Icon.icns").path(percentEncoded: false)]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Icon.icns and docs/icon.png" : "iconutil failed")
