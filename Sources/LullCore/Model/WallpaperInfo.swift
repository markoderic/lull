import Foundation

/// Names of the files inside a wallpaper's folder.
public enum WallpaperFile {
    public static let info = "info.json"
    public static let prepared = "prepared.mp4"
    public static let still = "still.png"
    public static let thumbnail = "thumb.jpg"
    public static let partialSuffix = ".partial"

    public static func smooth(_ rate: Int) -> String { "smooth-\(rate).mp4" }
    public static func limit(_ fps: Int) -> String { "limit-\(fps).mp4" }
}

/// Everything remembered about one wallpaper. Stored as `info.json` in its folder.
public struct WallpaperInfo: Codable, Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case gif, video
    }

    public enum Mode: String, Codable, Sendable {
        case animated, still
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var addedAt: Date
    /// The copy of the source file. `nil` when `prepared.mp4` is itself the original.
    public var originalFilename: String?
    public var width: Int
    public var height: Int
    public var duration: Double
    public var sourceFPS: Double
    public var frameCount: Int
    /// Start time of each frame, present only when frames aren't evenly spaced.
    public var frameTimes: [Double]?
    public var mode: Mode
    public var stillFrame: Int
    public var smoothMotion: Bool
    public var smoothRate: Int
    public var frameLimit: Int?

    public init(
        id: UUID,
        name: String,
        kind: Kind,
        addedAt: Date,
        originalFilename: String?,
        width: Int,
        height: Int,
        duration: Double,
        sourceFPS: Double,
        frameCount: Int,
        frameTimes: [Double]? = nil,
        mode: Mode = .animated,
        stillFrame: Int = 0,
        smoothMotion: Bool = false,
        smoothRate: Int = 120,
        frameLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.addedAt = addedAt
        self.originalFilename = originalFilename
        self.width = width
        self.height = height
        self.duration = duration
        self.sourceFPS = sourceFPS
        self.frameCount = frameCount
        self.frameTimes = frameTimes
        self.mode = mode
        self.stillFrame = stillFrame
        self.smoothMotion = smoothMotion
        self.smoothRate = smoothRate
        self.frameLimit = frameLimit
    }

    /// A file with one frame can't animate.
    public var isStillOnly: Bool { frameCount <= 1 }

    /// The file that should play for the current settings.
    public var playbackFilename: String {
        if smoothMotion { return WallpaperFile.smooth(smoothRate) }
        if let frameLimit { return WallpaperFile.limit(frameLimit) }
        return WallpaperFile.prepared
    }

    /// The start time of a frame in the base prepared file.
    public func time(forFrame frame: Int) -> Double {
        let clamped = min(max(frame, 0), max(frameCount - 1, 0))
        if let frameTimes, clamped < frameTimes.count { return frameTimes[clamped] }
        guard sourceFPS > 0 else { return 0 }
        return Double(clamped) / sourceFPS
    }

    /// The frame showing at a playback time.
    public func frame(forTime time: Double) -> Int {
        guard time > 0 else { return 0 }
        if let frameTimes {
            let index = frameTimes.lastIndex { $0 <= time } ?? 0
            return min(index, max(frameCount - 1, 0))
        }
        return min(Int(time * sourceFPS), max(frameCount - 1, 0))
    }

    /// Smooth Motion rates that add frames and that a connected display can show.
    public func availableSmoothRates(displayMaxFPS: Int) -> [Int] {
        guard !isStillOnly else { return [] }
        return [60, 120].filter { Double($0) > sourceFPS * 1.01 && $0 <= displayMaxFPS }
    }

    /// Frame limits worth offering, fastest first. "Original" is always available too.
    public var availableFrameLimits: [Int] {
        guard sourceFPS >= 59 else { return [] }
        return sourceFPS > 61 ? [60, 30] : [30]
    }
}
