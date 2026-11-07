// Draws the picture shown when the download page's link is shared, on LinkedIn for example.
// Usage: swift scripts/make-share-image.swift docs/images/share.png
//
// It's the page's hero in one frame: the same sky, the icon's moon and hills, and the panel hanging
// from the top edge. Text stays on the left, clear of the hills, where it reads at thumbnail size.
import AppKit

let width: CGFloat = 1200, height: CGFloat = 627

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// The sky. Coordinates start at the bottom left.
let sky = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(0xF7A77C), color(0xB7568F), color(0x47307F), color(0x17153F)] as CFArray,
    locations: [0, 0.3, 0.68, 1]
)!
context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])

// The moon, with its glow.
let moon = CGPoint(x: 660, y: 470)
let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(0xFFF3DC, 0.34), color(0xFFF3DC, 0)] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(glow, startCenter: moon, startRadius: 30, endCenter: moon, endRadius: 190, options: [])
context.setFillColor(color(0xFFF3DC))
context.fillEllipse(in: CGRect(x: moon.x - 44, y: moon.y - 44, width: 88, height: 88))

// The hills, back to front.
func hill(_ fill: UInt32, _ points: [(CGFloat, CGFloat)]) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: points[0].1))
    var previous = CGPoint(x: 0, y: points[0].1)
    for (x, y) in points.dropFirst() {
        let middle = (previous.x + x) / 2
        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: middle, y: previous.y), control2: CGPoint(x: middle, y: y))
        previous = CGPoint(x: x, y: y)
    }
    path.addLine(to: CGPoint(x: width, y: 0))
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(color(fill))
    context.fillPath()
}
hill(0x6B3F93, [(0, 150), (300, 205), (620, 120), (900, 225), (1200, 140)])
hill(0x47307F, [(0, 105), (260, 70), (560, 150), (860, 80), (1200, 130)])
hill(0x241A4D, [(0, 55), (340, 92), (700, 32), (1000, 70), (1200, 40)])

// The panel, hanging from the top edge.
let panelWidth: CGFloat = 372
let panelHeight = panelWidth * 985 / 640
let panelFrame = CGRect(x: width - panelWidth - 70, y: height - panelHeight + 34, width: panelWidth, height: panelHeight)
let panelPath = CGPath(roundedRect: panelFrame, cornerWidth: 22, cornerHeight: 22, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 44, color: color(0x17153F, 0.55))
context.addPath(panelPath)
context.setFillColor(color(0x323232))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(panelPath)
context.clip()
NSImage(contentsOfFile: "docs/images/panel-dark.png")!.draw(in: panelFrame)
context.restoreGState()

// The words.
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func draw(_ text: String, at point: CGPoint, font: NSFont, color fill: UInt32, lineHeight: CGFloat? = nil, width lineWidth: CGFloat = 640) {
    let style = NSMutableParagraphStyle()
    if let lineHeight {
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
    }
    let string = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: color(fill))!,
        .paragraphStyle: style,
    ])
    let bounds = string.boundingRect(with: CGSize(width: lineWidth, height: 400), options: [.usesLineFragmentOrigin])
    string.draw(with: CGRect(x: point.x, y: point.y - bounds.height, width: lineWidth, height: bounds.height), options: [.usesLineFragmentOrigin])
}

let left: CGFloat = 76
NSImage(contentsOfFile: "docs/images/icon.png")!.draw(in: CGRect(x: left - 8, y: height - 76 - 104, width: 104, height: 104))
draw("Lull", at: CGPoint(x: left, y: height - 196), font: rounded(112, .bold), color: 0xFFF3DC)
draw("Any GIF or video as\nyour Mac wallpaper", at: CGPoint(x: left, y: height - 334), font: rounded(50, .semibold), color: 0xFFF3DC, lineHeight: 60)
draw("Free, with no account and no ads", at: CGPoint(x: left, y: height - 472), font: rounded(29, .medium), color: 0xFFF3DC)

let output = CommandLine.arguments.dropFirst().first ?? "docs/images/share.png"
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
