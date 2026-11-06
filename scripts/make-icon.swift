// Draws the app icon: a calm dusk landscape, because Lull rests when nobody's looking.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

/// A superellipse, the same family of shape as a macOS icon's continuous corners.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let (cx, cy, a, b) = (rect.midX, rect.midY, rect.width / 2, rect.height / 2)
    for step in 0...720 {
        let t = CGFloat(step) / 720 * 2 * .pi
        let (c, s) = (cos(t), sin(t))
        let x = cx + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = cy + b * copysign(pow(abs(s), 2 / exponent), s)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    // Apple's icon grid: an 824-point shape centered on a 1024-point canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: tile)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 26 * scale, color: color(0x000000, 0.28))
    context.addPath(shape)
    context.setFillColor(color(0x1A1747))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    let sky = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x17153F), color(0x47307F), color(0xB7568F), color(0xF7A77C)] as CFArray,
        locations: [0, 0.42, 0.74, 1]
    )!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 330), options: [.drawsAfterEndLocation])

    let moon = CGPoint(x: 640, y: 640)
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFF1D6, 0.45), color(0xFFF1D6, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(glow, startCenter: moon, startRadius: 70, endCenter: moon, endRadius: 250, options: [])
    context.setFillColor(color(0xFFF3DC))
    context.fillEllipse(in: CGRect(x: moon.x - 88, y: moon.y - 88, width: 176, height: 176))

    let dunes: [(base: CGFloat, height: CGFloat, length: CGFloat, phase: CGFloat, fill: UInt32)] = [
        (448, 58, 760, 0.4, 0x6A3F8F),
        (356, 66, 900, 2.1, 0x41296F),
        (258, 54, 720, 3.6, 0x241A4D),
    ]
    for dune in dunes {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        for x in stride(from: CGFloat(0), through: 1024, by: 4) {
            let wave = sin(x / dune.length * 2 * .pi + dune.phase) + 0.35 * sin(x / dune.length * 4.6 * .pi + dune.phase * 1.7)
            path.addLine(to: CGPoint(x: x, y: dune.base + dune.height * wave))
        }
        path.addLine(to: CGPoint(x: 1024, y: 0))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color(dune.fill))
        context.fillPath()
    }
    context.restoreGState()
    return context.makeImage()!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 2 ? "@2x" : ""
    let url = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawIcon(size: points * scale), nil)
    CGImageDestinationFinalize(destination)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
