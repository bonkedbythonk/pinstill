import Foundation

public enum WakeSync {
    /// A sync after the Mac wakes is due when none ran in the last `minimumGap` seconds.
    /// Keeps a Mac that sleeps and wakes all day from asking Pinterest every time.
    public static func isDue(lastSync: Date?, now: Date, minimumGap: TimeInterval = 3600) -> Bool {
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) >= minimumGap
    }
}

extension PixelSize {
    public func hasMorePixels(than other: PixelSize) -> Bool { width * height > other.width * other.height }
}
