import AppKit
import SwiftUI

/// Shows the wallpaper in the panel. It shares the desktop's player, so it adds no decoding work.
struct PreviewSurfaceView: NSViewRepresentable {
    let engine: WallpaperEngine

    func makeNSView(context: Context) -> PreviewHostView {
        PreviewHostView(engine: engine)
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {}

    static func dismantleNSView(_ view: PreviewHostView, coordinator: ()) {
        view.detach()
    }
}

final class PreviewHostView: NSView {
    private let engine: WallpaperEngine
    private var surface: WallpaperSurface?

    init(engine: WallpaperEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if let layer {
            let surface = WallpaperSurface(host: layer)
            self.surface = surface
            engine.add(preview: surface)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        surface?.resize(to: bounds)
    }

    func detach() {
        if let surface { engine.remove(preview: surface) }
        surface = nil
    }
}
