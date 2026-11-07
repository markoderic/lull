// Draws the installer window's background, which shows people what to do.
// Usage: swift scripts/make-dmg-background.swift Resources/dmg-background.tiff
//
// The middle tones are deliberate: Finder draws icon labels in black or white depending on the
// person's light or dark mode, and they need to be readable on this in both.
import AppKit

let width: CGFloat = 640, height: CGFloat = 400

func render(scale: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: alpha
        )
    }

    let sky = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x5E4C9E), color(0x8A6BB0), color(0xA97FB3)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // The arrow between the two icons, which Finder places at y = 195 from the top.
    let arrowY = height - 195
    context.setStrokeColor(color(0xFFF3DC))
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 262, y: arrowY))
    context.addLine(to: CGPoint(x: 378, y: arrowY))
    context.strokePath()
    context.move(to: CGPoint(x: 352, y: arrowY + 24))
    context.addLine(to: CGPoint(x: 378, y: arrowY))
    context.addLine(to: CGPoint(x: 352, y: arrowY - 24))
    context.strokePath()

    // The two lines of instructions, in the style of the app's rounded type.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    }
    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(size: size, weight: weight),
            .foregroundColor: NSColor(cgColor: color(0xFFF3DC))!,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        string.draw(at: CGPoint(x: (width - string.size().width) / 2, y: y))
    }
    draw("Drag Lull to Applications", size: 26, weight: .semibold, y: height - 72)
    // Finder's title bar takes up part of the window's height, which cuts off the bottom of this
    // picture, so this line sits well above the picture's edge.
    draw("Then open Lull from your Applications folder.", size: 14, weight: .regular, y: 68)
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = CommandLine.arguments[1]
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lull-dmg-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let one = folder.appendingPathComponent("background.png"), two = folder.appendingPathComponent("background@2x.png")
writePNG(render(scale: 1), to: one)
writePNG(render(scale: 2), to: two)

// One file holding both resolutions, so it's crisp on Retina screens and normal on others.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
process.arguments = ["-cathidpicheck", one.path, two.path, "-out", output]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
