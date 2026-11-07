import Foundation

/// A screen resolution a wallpaper has been converted to fit. HEVC needs even dimensions.
public struct FitSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(screenWidth: Int, screenHeight: Int) {
        width = screenWidth + screenWidth % 2
        height = screenHeight + screenHeight % 2
    }

    var label: String { "\(width)x\(height)" }
}

/// How well a file suits a screen, and the plain advice that goes with it.
public enum WallpaperFit: Equatable, Sendable {
    case good
    case soft
    case cropped(hiddenPercent: Int)

    private static let croppedAbovePercent = 25
    private static let softAboveScale = 2.0

    public static func evaluate(
        mediaWidth: Int,
        mediaHeight: Int,
        kind: WallpaperInfo.Kind,
        screenWidth: Int,
        screenHeight: Int
    ) -> WallpaperFit {
        guard mediaWidth > 0, mediaHeight > 0, screenWidth > 0, screenHeight > 0 else { return .good }
        let mediaAspect = Double(mediaWidth) / Double(mediaHeight)
        let screenAspect = Double(screenWidth) / Double(screenHeight)
        // Filling the screen crops whichever dimension doesn't match.
        let visible = min(mediaAspect / screenAspect, screenAspect / mediaAspect)
        let hidden = Int(((1 - visible) * 100).rounded())
        if hidden > croppedAbovePercent { return .cropped(hiddenPercent: hidden) }
        // Most GIFs are far smaller than a screen and that's what they are, so only videos get this.
        let scale = max(Double(screenWidth) / Double(mediaWidth), Double(screenHeight) / Double(mediaHeight))
        if kind == .video, scale > softAboveScale { return .soft }
        return .good
    }

    /// Advice to show under a wallpaper, or `nil` when there's nothing worth saying.
    public static func note(for info: WallpaperInfo, screenWidth: Int, screenHeight: Int) -> String? {
        guard info.fitSize == nil else { return nil }
        let size = "\(screenWidth) × \(screenHeight)"
        switch evaluate(mediaWidth: info.width, mediaHeight: info.height, kind: info.kind, screenWidth: screenWidth, screenHeight: screenHeight) {
        case .good:
            return nil
        case .soft:
            return "This video is smaller than your screen, so it may look soft. A file around \(size) would look sharpest."
        case .cropped(let hidden):
            let shape = screenWidth >= screenHeight ? "landscape" : "vertical"
            return "Zoomed in to fill your screen, hiding about \(hidden)% of this file. Turn on Fit to Screen to see all of it, or use a \(shape) file around \(size)."
        }
    }

    /// Fit to Screen helps only when part of the picture is hidden. Enlarging can't add detail, so
    /// it isn't offered for a file that's merely small. Once on, it stays available to turn off.
    public static func canFit(_ info: WallpaperInfo, screenWidth: Int, screenHeight: Int) -> Bool {
        if info.fitSize != nil { return true }
        let fit = evaluate(mediaWidth: info.width, mediaHeight: info.height, kind: info.kind, screenWidth: screenWidth, screenHeight: screenHeight)
        if case .cropped = fit { return true }
        return false
    }

    /// The best file to look for, shown before anything has been added.
    public static func bestSizeText(screenWidth: Int, screenHeight: Int) -> String? {
        guard screenWidth > 0, screenHeight > 0 else { return nil }
        let shape = screenWidth >= screenHeight ? "landscape" : "vertical"
        return "Best fit for this screen: \(screenWidth) × \(screenHeight), \(shape)."
    }
}
