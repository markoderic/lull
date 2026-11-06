import Foundation

/// One output frame of a Smooth Motion version.
public struct FrameTick: Equatable, Sendable {
    public var index: Int
    public var time: Double
    /// How far between the pair's two source frames it falls. 0 means it is the first source frame.
    public var phase: Float
}

public enum FrameTiming {
    /// Browsers treat GIF delays under about 10 ms as 100 ms, so GIFs are authored expecting that.
    public static func normalizedDelay(_ delay: Double) -> Double {
        delay < 0.011 ? 0.1 : delay
    }

    public static func startTimes(delays: [Double]) -> [Double] {
        var time = 0.0
        return delays.map { delay in
            defer { time += delay }
            return time
        }
    }

    public static func isUniform(delays: [Double]) -> Bool {
        guard let low = delays.min(), let high = delays.max() else { return true }
        return high - low < 0.0005
    }

    public static func outputFrameCount(duration: Double, fps: Int) -> Int {
        max(1, Int((duration * Double(fps)).rounded()))
    }

    /// The output frames that fall within one pair of source frames, `start` inclusive and `end` exclusive.
    public static func ticks(start: Double, end: Double, fps: Int, totalOutputFrames: Int) -> [FrameTick] {
        var ticks: [FrameTick] = []
        let rate = Double(fps)
        let span = end - start
        var index = Int((start * rate - 1e-6).rounded(.up))
        while index < totalOutputFrames {
            let time = Double(index) / rate
            guard time < end - 1e-9 else { break }
            let phase = span > 0 ? (time - start) / span : 0
            ticks.append(FrameTick(index: index, time: time, phase: phase < 1e-4 ? 0 : Float(phase)))
            index += 1
        }
        return ticks
    }
}

/// Decides which frames to keep when lowering a video's frame rate.
public struct FrameLimiter: Sendable {
    private let interval: Double
    private var nextTime = 0.0

    public init(limit: Int) {
        interval = 1 / Double(limit)
    }

    public mutating func shouldKeep(time: Double) -> Bool {
        guard time + 1e-6 >= nextTime else { return false }
        repeat { nextTime += interval } while nextTime <= time + 1e-6
        return true
    }
}
