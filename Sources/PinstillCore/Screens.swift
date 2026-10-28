import AppKit

public enum Screens {
    /// Native pixel size of each connected display, in `NSScreen.screens` order (main first).
    @MainActor
    public static func pixelSizes() -> [PixelSize] {
        NSScreen.screens.map { screen in
            let scale = screen.backingScaleFactor
            return PixelSize(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
        }
    }

    /// Stable id of a display: survives reconnecting it and restarting the Mac, unlike its index.
    @MainActor
    public static func id(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Render target: the connected display with the most pixels (fallback: 14" MacBook Pro).
    @MainActor
    public static func largestPixelSize() -> PixelSize {
        pixelSizes().max { $0.width * $0.height < $1.width * $1.height } ?? PixelSize(width: 3024, height: 1964)
    }
}
