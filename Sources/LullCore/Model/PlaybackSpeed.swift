import Foundation

/// How fast a wallpaper plays. Multiples read better than percentages here, and they're what people
/// know from video players. Normal sits in the middle of the slider, with slower to the left and
/// faster to the right.
public enum PlaybackSpeed {
    public static let stops: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]

    private static let choppyBelowFPS = 15.0

    /// The nearest position on the scale, so a damaged saved value can't leave it.
    public static func index(of speed: Double) -> Int {
        stops.indices.min { abs(stops[$0] - speed) < abs(stops[$1] - speed) } ?? stops.count / 2
    }

    public static func label(for speed: Double) -> String {
        speed == 1 ? "Normal" : String(format: "%g×", speed)
    }

    /// Slowing a file down spreads out its frames, and generated frames fill the gaps.
    public static func hint(speed: Double, sourceFPS: Double, smoothMotion: Bool, canUseSmoothMotion: Bool) -> String? {
        guard speed < 1, !smoothMotion, canUseSmoothMotion else { return nil }
        let effective = sourceFPS * speed
        guard effective < choppyBelowFPS else { return nil }
        return "That's about \(max(Int(effective.rounded()), 1)) frames a second. Smooth Motion keeps it fluid."
    }
}
