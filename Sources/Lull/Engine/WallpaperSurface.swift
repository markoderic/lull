import AppKit
@preconcurrency import AVFoundation
import QuartzCore

/// One place the wallpaper is drawn: a desktop window, or the panel's preview.
@MainActor
final class WallpaperSurface {
    private let playerLayer = AVPlayerLayer()
    private let stillLayer = CALayer()
    private var readyObservation: NSKeyValueObservation?
    var onReady: ((WallpaperSurface) -> Void)?

    static let fadeDuration: TimeInterval = 0.25

    init(host: CALayer) {
        host.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        stillLayer.contentsGravity = .resizeAspectFill
        stillLayer.masksToBounds = true
        let noAnimation: [String: any CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(),
        ]
        stillLayer.actions = noAnimation
        playerLayer.actions = noAnimation
        host.addSublayer(playerLayer)
        host.addSublayer(stillLayer)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onReady?(self)
            }
        }
    }

    var isReadyForDisplay: Bool { playerLayer.isReadyForDisplay }
    var hasStill: Bool { stillLayer.contents != nil }

    func resize(to bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        stillLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(_ player: AVPlayer?) {
        playerLayer.player = player
    }

    func setStill(_ image: CGImage?, fade: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = Self.fadeDuration
            stillLayer.add(transition, forKey: "fade")
        } else {
            stillLayer.removeAnimation(forKey: "fade")
        }
        stillLayer.contents = image
        CATransaction.commit()
    }
}
