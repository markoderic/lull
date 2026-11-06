import Testing
@testable import LullCore

@Suite("Frame timing")
struct FrameTimingTests {
    @Test(arguments: [0.0, 0.005, 0.01])
    func verySmallDelaysBecomeTheBrowserDefault(_ delay: Double) {
        #expect(FrameTiming.normalizedDelay(delay) == 0.1)
    }

    @Test func normalDelaysAreKept() {
        #expect(FrameTiming.normalizedDelay(0.011) == 0.011)
        #expect(FrameTiming.normalizedDelay(0.08) == 0.08)
    }

    @Test func startTimesAccumulateDelays() {
        #expect(FrameTiming.startTimes(delays: [0.5, 0.25, 0.25]) == [0, 0.5, 0.75])
    }

    @Test func uniformDelaysAreDetected() {
        #expect(FrameTiming.isUniform(delays: [0.04, 0.04, 0.04]))
        #expect(!FrameTiming.isUniform(delays: [0.04, 0.5, 0.04]))
        #expect(FrameTiming.isUniform(delays: [0.04]))
    }

    @Test func outputFrameCountFromDurationAndRate() {
        #expect(FrameTiming.outputFrameCount(duration: 4, fps: 120) == 480)
        #expect(FrameTiming.outputFrameCount(duration: 4, fps: 60) == 240)
        #expect(FrameTiming.outputFrameCount(duration: 0, fps: 60) == 1)
    }

    @Test func ticksInsideAPairCarryTheirPhase() {
        let ticks = FrameTiming.ticks(start: 0, end: 0.04, fps: 100, totalOutputFrames: 400)
        #expect(ticks.count == 4)
        #expect(ticks[0].index == 0)
        #expect(ticks[0].phase == 0)
        #expect(abs(ticks[1].time - 0.01) < 1e-9)
        #expect(abs(ticks[1].phase - 0.25) < 1e-6)
        #expect(abs(ticks[3].phase - 0.75) < 1e-6)
    }

    @Test func aTickLandingOnAPairBoundaryBelongsToTheLaterPair() {
        let first = FrameTiming.ticks(start: 0, end: 0.5, fps: 2, totalOutputFrames: 10)
        let second = FrameTiming.ticks(start: 0.5, end: 1, fps: 2, totalOutputFrames: 10)
        #expect(first.map(\.index) == [0])
        #expect(second.map(\.index) == [1])
    }

    @Test func ticksStopAtTheOutputTotal() {
        #expect(FrameTiming.ticks(start: 0, end: 10, fps: 10, totalOutputFrames: 3).map(\.index) == [0, 1, 2])
    }

    @Test func gifAt12Point5ToOneTwentyProducesEveryOutputFrameExactlyOnce() {
        let delays = Array(repeating: 0.08, count: 50)
        let starts = FrameTiming.startTimes(delays: delays)
        let duration = delays.reduce(0, +)
        let total = FrameTiming.outputFrameCount(duration: duration, fps: 120)
        var indices: [Int] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : duration
            indices += FrameTiming.ticks(start: start, end: end, fps: 120, totalOutputFrames: total).map(\.index)
        }
        #expect(total == 480)
        #expect(indices == Array(0..<480))
    }

    @Test func frameLimiterKeepsEveryOtherFrameAtHalfRate() {
        var limiter = FrameLimiter(limit: 60)
        let kept = (0..<12).filter { limiter.shouldKeep(time: Double($0) / 120) }
        #expect(kept == [0, 2, 4, 6, 8, 10])
    }

    @Test func frameLimiterKeepsEverythingAlreadySlowerThanTheLimit() {
        var limiter = FrameLimiter(limit: 60)
        let kept = (0..<6).filter { limiter.shouldKeep(time: Double($0) / 30) }
        #expect(kept == [0, 1, 2, 3, 4, 5])
    }

    @Test func frameLimiterHandlesRatesThatAreNotExactMultiples() {
        var limiter = FrameLimiter(limit: 30)
        let kept = (0..<300).filter { limiter.shouldKeep(time: Double($0) / 59.94) }
        #expect(abs(kept.count - 150) <= 1)
    }
}

@Suite("Enlarge policy")
struct EnlargePolicyTests {
    @Test func smallPixelArtScalesFourTimesWithSharpPixels() {
        let plan = EnlargePolicy.plan(width: 320, height: 180, isPixelArt: true)
        #expect(plan == EnlargePlan(scale: 4, outputWidth: 1280, outputHeight: 720, sharpPixels: true))
    }

    @Test func otherSmallGIFsScaleWithSmoothing() {
        let plan = EnlargePolicy.plan(width: 320, height: 180, isPixelArt: false)
        #expect(plan == EnlargePlan(scale: 4, outputWidth: 1280, outputHeight: 720, sharpPixels: false))
    }

    @Test func scaleKeepsTheLongerSideWithinTheLimit() {
        #expect(EnlargePolicy.plan(width: 500, height: 280, isPixelArt: true).scale == 3)
        #expect(EnlargePolicy.plan(width: 800, height: 450, isPixelArt: true).scale == 2)
        #expect(EnlargePolicy.plan(width: 400, height: 1000, isPixelArt: true).scale == 1)
    }

    @Test func gifsAtLeast1280WideAreNotEnlarged() {
        let plan = EnlargePolicy.plan(width: 1280, height: 720, isPixelArt: true)
        #expect(plan.scale == 1)
        #expect(plan.outputWidth == 1280)
    }

    @Test func oddSizesRoundUpToEven() {
        let plan = EnlargePolicy.plan(width: 1333, height: 749, isPixelArt: false)
        #expect(plan.outputWidth == 1334)
        #expect(plan.outputHeight == 750)
    }

    @Test func oddSizesAreEvenAfterScaling() {
        let plan = EnlargePolicy.plan(width: 333, height: 187, isPixelArt: true)
        #expect(plan.outputWidth % 2 == 0)
        #expect(plan.outputHeight % 2 == 0)
    }

    @Test func tinyGIFsReachTheEncoderMinimum() {
        let plan = EnlargePolicy.plan(width: 8, height: 8, isPixelArt: true)
        #expect(plan.outputWidth >= 64)
        #expect(plan.outputHeight >= 64)
        #expect(plan.scale == 8)
    }

    @Test func extremeAspectRatiosStillReachTheMinimum() {
        let plan = EnlargePolicy.plan(width: 1000, height: 2, isPixelArt: false)
        #expect(plan.outputHeight >= 64)
    }
}

@Suite("Pixel art detection")
struct PixelArtDetectorTests {
    @Test func flatColorBlocksAreRecognizedAsPixelArt() {
        let colors: [UInt32] = [0x1D2B53FF, 0x7E2553FF, 0x008751FF, 0xFF77A8FF]
        let pixels = (0..<(64 * 64)).map { i -> UInt32 in
            let x = i % 64, y = i / 64
            return colors[((x / 8) + (y / 8)) % colors.count]
        }
        #expect(PixelArtDetector.isPixelArt(pixels: pixels, width: 64, height: 64))
    }

    @Test func photographicNoiseIsNot() {
        var generator = SeededGenerator(seed: 7)
        let pixels = (0..<(64 * 64)).map { _ in UInt32.random(in: 0...UInt32.max, using: &generator) }
        #expect(!PixelArtDetector.isPixelArt(pixels: pixels, width: 64, height: 64))
    }

    @Test func bandedGradientsWithManyColorsAreNot() {
        let pixels = (0..<(256 * 64)).map { i -> UInt32 in
            let x = i % 256
            return UInt32(x) << 24 | UInt32(255 - x) << 16 | UInt32(x / 2) << 8 | 0xFF
        }
        var stretched: [UInt32] = []
        for y in 0..<64 {
            for x in 0..<(256 * 4) { stretched.append(pixels[y * 256 + x / 4]) }
        }
        #expect(!PixelArtDetector.isPixelArt(pixels: stretched, width: 1024, height: 64))
    }
}

/// A small deterministic generator so noise-based tests never flake.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
