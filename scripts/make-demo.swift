// Draws the illustrated demo in the README, and the video for sharing. It isn't a screen recording.
// The wallpaper is drawn here rather than taken from anyone's library, so all of it can be shared.
//
// From the repository root, with ffmpeg installed:
//   swiftc -O -swift-version 5 -o .build/make-demo scripts/make-demo.swift
//   .build/make-demo docs/media               writes lull-demo.mp4, lull-demo.gif and lull-demo.png
//   .build/make-demo --still 5.2 frame.png    writes one frame, for checking
import AppKit

let width = 1280, height = 720
let W = CGFloat(width), H = CGFloat(height)
let fps = 30.0

// MARK: Timeline, in seconds

let hookEnd = 2.5, dropEnd = 6.5, restEnd = 11.0, dayEnd = 14.5, speedEnd = 17.75, total = 20.75

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
    let x = clamp((t - a) / (b - a))
    return x * x * (3 - 2 * x)
}
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// The speed shown on the slider in the speed scene.
func shownSpeed(_ t: Double) -> Double {
    let local = t - dayEnd
    guard local >= 0, t < speedEnd else { return 1 }
    if local < 1.3 { return mix(1, 2, ramp(local, 0.45, 1.05)) }
    return mix(2, 0.25, ramp(local, 1.5, 2.1))
}

/// A covered desktop stops, then picks up where it left off.
let coverStart = dropEnd + 1.25, coverEnd = dropEnd + 3.55

/// The wallpaper's own clock, so pausing and speed changes keep its motion continuous.
let wallClock: [Double] = {
    var clock = [0.0]
    let step = 1.0 / 240
    var t = 0.0
    while t < total + 1 {
        let rate = t >= coverStart && t < coverEnd ? 0 : shownSpeed(t)
        clock.append(clock.last! + rate * step)
        t += step
    }
    return clock
}()
func wallTime(_ t: Double) -> Double { wallClock[min(Int(t * 240), wallClock.count - 1)] + 3 }

/// 0 is day, 1 is dusk and 2 is night.
func skyPhase(_ t: Double) -> Double {
    if t < restEnd { return 1 }
    if t < dayEnd {
        let local = t - restEnd
        return local < 1.35 ? 1 - ramp(local, 0, 0.35) : 2 * ramp(local, 1.35, 2.35)
    }
    return 2 - ramp(t - dayEnd, 0, 0.4)
}

// MARK: Colour

struct RGB {
    var r, g, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 255) / 255
        g = Double((hex >> 8) & 255) / 255
        b = Double(hex & 255) / 255
    }
    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
    func cg(_ alpha: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    func ns(_ alpha: Double = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}
func blend(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    RGB(r: mix(a.r, b.r, t), g: mix(a.g, b.g, t), b: mix(a.b, b.b, t))
}
func phased(_ day: UInt32, _ dusk: UInt32, _ night: UInt32, _ p: Double) -> RGB {
    p <= 1 ? blend(RGB(day), RGB(dusk), p) : blend(RGB(dusk), RGB(night), p - 1)
}

let night = RGB(0x17153F), ink = RGB(0x241A4D), peach = RGB(0xF7A77C), moon = RGB(0xFFF3DC), haze = RGB(0xC9C1E6), mint = RGB(0x7BE3AE)

// MARK: Drawing surface

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let c = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
c.translateBy(x: 0, y: H)
c.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func text(
    _ s: String, x: CGFloat, y: CGFloat, width w: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
    color: RGB = moon, alpha: Double = 1, align: NSTextAlignment = .left, lineHeight: CGFloat? = nil
) {
    guard alpha > 0.001 else { return }
    let style = NSMutableParagraphStyle()
    style.alignment = align
    if let lineHeight {
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
    }
    NSAttributedString(string: s, attributes: [
        .font: font(size, weight), .foregroundColor: color.ns(alpha), .paragraphStyle: style,
    ]).draw(with: CGRect(x: x, y: y, width: w, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fill(_ rect: CGRect, radius: CGFloat = 0, _ color: CGColor) {
    c.addPath(rounded(rect, radius))
    c.setFillColor(color)
    c.fillPath()
}

let iconImage = NSImage(contentsOfFile: "docs/images/icon.png")!

// MARK: The wallpaper

struct Star { var x, y, phase, size: Double }
let stars: [Star] = {
    var seed: UInt64 = 7
    func next() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 33) / Double(UInt32.max >> 1)
    }
    return (0..<80).map { _ in Star(x: next(), y: next() * 0.58, phase: next() * 6.28, size: 1 + next() * 1.7) }
}()

func drawWallpaper(_ rect: CGRect, time wt: Double, phase p: Double) {
    c.saveGState()
    c.clip(to: rect)
    let scale = rect.width / W

    let sky = CGGradient(colorsSpace: space, colors: [
        phased(0x6FB7E8, 0x17153F, 0x090B26, p).cg(),
        phased(0x9AD0EE, 0x47307F, 0x14163F, p).cg(),
        phased(0xCFE8F0, 0xB7568F, 0x23235F, p).cg(),
        phased(0xFDE9C9, 0xF7A77C, 0x3A3678, p).cg(),
    ] as CFArray, locations: [0, 0.42, 0.68, 0.86])!
    c.drawLinearGradient(sky, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])

    // Stars come out as the sky darkens.
    let starAlpha = p < 0.75 ? 0 : (p <= 1 ? (p - 0.75) * 2.4 : 0.6 + (p - 1) * 0.4)
    if starAlpha > 0 {
        for star in stars {
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(wt * 2.4 + star.phase))
            let size = max(star.size * scale * 1.5, 1)
            c.setFillColor(moon.cg(starAlpha * twinkle))
            c.fillEllipse(in: CGRect(x: rect.minX + star.x * rect.width, y: rect.minY + star.y * rect.height, width: size, height: size))
        }
        // A shooting star now and then.
        let streak = wt.truncatingRemainder(dividingBy: 5)
        if streak < 0.6 {
            let run = Int(wt / 5)
            let startX = rect.minX + rect.width * (0.14 + 0.13 * Double(run % 4))
            let startY = rect.minY + rect.height * (0.08 + 0.05 * Double(run % 3))
            let head = streak / 0.6
            let from = CGPoint(x: startX + rect.width * 0.2 * max(head - 0.25, 0), y: startY + rect.height * 0.13 * max(head - 0.25, 0))
            let to = CGPoint(x: startX + rect.width * 0.2 * head, y: startY + rect.height * 0.13 * head)
            c.setStrokeColor(moon.cg(starAlpha * (1 - head)))
            c.setLineWidth(max(2.4 * scale, 1))
            c.setLineCap(.round)
            c.move(to: from)
            c.addLine(to: to)
            c.strokePath()
        }
    }

    // The sun by day and the moon by night, with a slow pulse in the glow.
    let discX = rect.minX + rect.width * 0.66
    let discY = rect.minY + rect.height * (p <= 1 ? mix(0.2, 0.34, p) : mix(0.34, 0.22, p - 1))
    let radius = 52 * scale
    let disc = CGPoint(x: discX, y: discY)
    let glowColor = phased(0xFFF6D6, 0xFFF3DC, 0xFFF3DC, p)
    let glow = CGGradient(colorsSpace: space, colors: [glowColor.cg(0.34 + 0.06 * sin(wt * 1.3)), glowColor.cg(0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: disc, startRadius: radius * 0.6, endCenter: disc, endRadius: radius * 4.2, options: [])
    c.setFillColor(glowColor.cg())
    c.fillEllipse(in: CGRect(x: discX - radius, y: discY - radius, width: radius * 2, height: radius * 2))

    // Clouds.
    let cloudColor = phased(0xFFFFFF, 0xF7A77C, 0x8B87C9, p)
    let cloudAlpha = p <= 1 ? mix(0.82, 0.3, p) : mix(0.3, 0.17, p - 1)
    for i in 0..<6 {
        let span = 1.5
        let x = (0.13 + Double(i) * 0.27 + wt * (0.016 + 0.007 * Double(i))).truncatingRemainder(dividingBy: span) - 0.25
        let y = 0.07 + 0.042 * Double(i)
        let size = 0.05 + 0.012 * Double((i * 5) % 4)
        let cx = rect.minX + rect.width * x, cy = rect.minY + rect.height * y
        let w = rect.width * size, h = w * 0.32
        // Fade the whole cloud at once, so its parts don't show through each other.
        c.saveGState()
        c.setAlpha(cloudAlpha)
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.setFillColor(cloudColor.cg())
        c.addPath(rounded(CGRect(x: cx - w * 1.1, y: cy, width: w * 2.2, height: h), h / 2))
        c.fillPath()
        c.fillEllipse(in: CGRect(x: cx - w * 0.6, y: cy - h * 0.72, width: w * 0.95, height: h * 1.5))
        c.fillEllipse(in: CGRect(x: cx + w * 0.02, y: cy - h * 0.42, width: w * 0.72, height: h * 1.2))
        c.endTransparencyLayer()
        c.restoreGState()
    }

    // Hills, back to front, drifting at different speeds.
    func hill(_ base: Double, _ amp: Double, _ freq: Double, _ drift: Double, _ color: RGB) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        var x = 0.0
        let stepWidth = max(rect.width / 120, 2)
        while x <= Double(rect.width) + Double(stepWidth) {
            let u = x / Double(rect.width)
            let phase = wt * drift
            let wave = 0.62 * sin(u * freq * 6.283 + phase) + 0.38 * sin(u * freq * 14.7 + phase * 1.7 + 1.1)
            path.addLine(to: CGPoint(x: rect.minX + x, y: rect.minY + rect.height * (base - amp * wave)))
            x += Double(stepWidth)
        }
        path.addLine(to: CGPoint(x: rect.maxX + stepWidth, y: rect.maxY))
        path.closeSubpath()
        c.addPath(path)
        c.setFillColor(color.cg())
        c.fillPath()
    }
    hill(0.70, 0.055, 1.05, 0.09, phased(0x7DBB9E, 0x6B3F93, 0x2B2A66, p))
    hill(0.80, 0.05, 1.35, 0.15, phased(0x58A184, 0x47307F, 0x1E1D4E, p))
    hill(0.90, 0.04, 0.85, 0.23, phased(0x2F7A6A, 0x241A4D, 0x111134, p))
    c.restoreGState()
}

// MARK: The little Mac

let mac = CGRect(x: 508, y: 104, width: 716, height: 462)
let menuHeight: CGFloat = 25

func drawFolder(_ x: CGFloat, _ y: CGFloat, _ label: String) {
    let blue = RGB(0x2F86E0)
    fill(CGRect(x: x + 7, y: y, width: 20, height: 8), radius: 3, RGB(0x1F68BC).cg())
    fill(CGRect(x: x + 7, y: y + 4, width: 42, height: 30), radius: 4, blue.cg())
    // Desktop labels have a shadow on a real Mac too, so they read on any wallpaper.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: RGB(0x090B26).cg(0.9))
    text(label, x: x - 12, y: y + 37, width: 80, size: 13, weight: .semibold, color: RGB(0xFFFFFF), align: .center)
    c.restoreGState()
}

func drawDock() {
    let colors: [UInt32] = [0x5AC8FA, 0xFF9F0A, 0x34C759, 0xFF375F, 0xBF5AF2, 0xFFD60A, 0xA6A6AD]
    let tile: CGFloat = 30, gap: CGFloat = 7
    let wide = CGFloat(colors.count) * (tile + gap) + gap + 8
    let dock = CGRect(x: mac.midX - wide / 2, y: mac.maxY - tile - 21, width: wide, height: tile + 13)
    fill(dock, radius: 13, RGB(0xFFFFFF).cg(0.26))
    for (i, color) in colors.enumerated() {
        fill(CGRect(x: dock.minX + 4 + gap + CGFloat(i) * (tile + gap), y: dock.minY + 6.5, width: tile, height: tile), radius: 8, RGB(color).cg())
    }
}

func drawMenuBar(clock: String) {
    fill(CGRect(x: mac.minX, y: mac.minY, width: mac.width, height: menuHeight), RGB(0x101030).cg(0.42))
    text("Finder", x: mac.minX + 14, y: mac.minY + 4, width: 100, size: 13, weight: .bold)
    text(clock, x: mac.maxX - 104, y: mac.minY + 4, width: 92, size: 13, weight: .medium, align: .right)
    // Lull's menu bar icon is a small moon.
    c.setFillColor(moon.cg())
    c.fillEllipse(in: CGRect(x: mac.maxX - 130, y: mac.minY + 6.5, width: 12, height: 12))
}

func drawPanel(open: Double, loaded: Double, time wt: Double, phase p: Double) {
    guard open > 0 else { return }
    let frame = CGRect(x: mac.maxX - 300, y: mac.minY + menuHeight + 6, width: 212, height: 268)
    c.saveGState()
    c.setAlpha(open)
    c.translateBy(x: frame.maxX - 42, y: frame.minY)
    c.scaleBy(x: mix(0.93, 1, open), y: mix(0.93, 1, open))
    c.translateBy(x: -(frame.maxX - 42), y: -frame.minY)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: RGB(0x090B26).cg(0.5))
    fill(frame, radius: 14, RGB(0x323232).cg())
    c.restoreGState()

    let preview = CGRect(x: frame.minX + 12, y: frame.minY + 12, width: frame.width - 24, height: 118)
    fill(preview, radius: 9, RGB(0x414141).cg())
    if loaded < 1 {
        text("Add a GIF or video", x: preview.minX + 8, y: preview.minY + 30, width: preview.width - 16, size: 14, weight: .semibold, alpha: 1 - loaded, align: .center)
        text("Drop a file here, or use the + button below.", x: preview.minX + 14, y: preview.minY + 52, width: preview.width - 28, size: 11, color: haze, alpha: 1 - loaded, align: .center)
    }
    if loaded > 0 {
        c.saveGState()
        c.setAlpha(open * loaded)
        c.addPath(rounded(preview, 9))
        c.clip()
        drawWallpaper(preview, time: wt, phase: p)
        c.restoreGState()
    }
    // Animated or Still.
    let segment = CGRect(x: frame.minX + 12, y: preview.maxY + 12, width: frame.width - 24, height: 28)
    fill(segment, radius: 7, RGB(0x414141).cg())
    fill(CGRect(x: segment.minX + 2, y: segment.minY + 2, width: segment.width / 2 - 2, height: segment.height - 4), radius: 6, RGB(0x6B6B6B).cg())
    text("Animated", x: segment.minX, y: segment.minY + 6, width: segment.width / 2, size: 12.5, weight: .semibold, align: .center)
    text("Still", x: segment.midX, y: segment.minY + 6, width: segment.width / 2, size: 12.5, weight: .medium, color: haze, align: .center)
    // The library, with the + button.
    let tile = CGRect(x: frame.minX + 12, y: segment.maxY + 14, width: 56, height: 56)
    let plus = loaded > 0.5 ? tile.offsetBy(dx: 64, dy: 0) : tile
    if loaded > 0 {
        c.saveGState()
        c.setAlpha(open * loaded)
        c.addPath(rounded(tile, 9))
        c.clip()
        drawWallpaper(tile, time: wt, phase: p)
        c.restoreGState()
        c.addPath(rounded(tile, 9))
        c.setStrokeColor(RGB(0x3B82F6).cg(open * loaded))
        c.setLineWidth(2)
        c.strokePath()
    }
    fill(plus, radius: 9, RGB(0x4A4A4A).cg())
    text("+", x: plus.minX, y: plus.minY + 12, width: plus.width, size: 24, weight: .regular, color: haze, align: .center)
    c.restoreGState()
}

func drawCursor(_ x: CGFloat, _ y: CGFloat, alpha: Double) {
    guard alpha > 0 else { return }
    let path = CGMutablePath()
    path.addLines(between: [
        CGPoint(x: x, y: y), CGPoint(x: x, y: y + 21), CGPoint(x: x + 5.2, y: y + 16.2),
        CGPoint(x: x + 8.6, y: y + 24), CGPoint(x: x + 12, y: y + 22.5), CGPoint(x: x + 8.7, y: y + 15), CGPoint(x: x + 15.4, y: y + 15),
    ])
    path.closeSubpath()
    c.addPath(path)
    c.setFillColor(RGB(0x111111).cg(alpha))
    c.setStrokeColor(RGB(0xFFFFFF).cg(alpha))
    c.setLineWidth(1.5)
    c.drawPath(using: .fillStroke)
}

func drawAppWindow(cover: Double) {
    guard cover > 0 else { return }
    let top = mac.minY + menuHeight
    let frame = CGRect(x: mac.minX, y: top + (1 - cover) * (mac.height - menuHeight), width: mac.width, height: mac.height - menuHeight)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 6), blur: 24, color: RGB(0x090B26).cg(0.45))
    fill(frame, RGB(0xF5F5F7).cg())
    c.restoreGState()
    fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 38), RGB(0xE7E7EB).cg())
    for (i, color) in [UInt32(0xFC6862), 0xF3C058, 0x6BC889].enumerated() {
        c.setFillColor(RGB(color).cg())
        c.fillEllipse(in: CGRect(x: frame.minX + 16 + CGFloat(i) * 20, y: frame.minY + 13, width: 12, height: 12))
    }
    fill(CGRect(x: frame.midX - 150, y: frame.minY + 9, width: 300, height: 20), radius: 6, RGB(0xFFFFFF).cg())
    let bars: [(CGFloat, CGFloat)] = [(0.5, 26), (0.82, 12), (0.74, 12), (0.78, 12), (0.42, 12), (0.8, 12), (0.68, 12)]
    var y = frame.minY + 70
    for (share, tall) in bars {
        fill(CGRect(x: frame.minX + 60, y: y, width: (frame.width - 120) * share, height: tall), radius: tall / 2, RGB(0xD3D3DA).cg())
        y += tall + 20
    }
}

func drawMac(_ t: Double) {
    let dropLocal = t - hookEnd
    let wt = wallTime(t), p = skyPhase(t)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: RGB(0x090B26).cg(0.55))
    fill(mac, radius: 16, night.cg())
    c.restoreGState()

    c.saveGState()
    c.addPath(rounded(mac, 16))
    c.clip()

    drawWallpaper(mac, time: wt, phase: p)
    // A plain desktop until the first wallpaper is added.
    let plain = 1 - ramp(dropLocal, 1.85, 2.35)
    if plain > 0 {
        let gradient = CGGradient(colorsSpace: space, colors: [RGB(0x3B5A8C).cg(plain), RGB(0x7890B4).cg(plain)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: mac.minY), end: CGPoint(x: 0, y: mac.maxY), options: [])
    }
    drawFolder(mac.maxX - 76, mac.minY + menuHeight + 18, "Photos")
    drawFolder(mac.maxX - 76, mac.minY + menuHeight + 94, "Work")
    drawDock()

    // Rests when covered.
    let restLocal = t - dropEnd
    drawAppWindow(cover: ramp(restLocal, 0.6, 1.2) - ramp(restLocal, 3.0, 3.5))

    drawMenuBar(clock: t < restEnd + 1.2 ? "6:59 PM" : "7:00 PM")

    // Adding a file.
    let open = ramp(dropLocal, 0.2, 0.5) - ramp(dropLocal, 3.05, 3.3)
    drawPanel(open: t < dropEnd ? open : 0, loaded: ramp(dropLocal, 1.6, 1.9), time: wt, phase: p)
    if t > hookEnd, t < dropEnd {
        let start = CGPoint(x: mac.minX + 70, y: mac.maxY - 165)
        let target = CGPoint(x: mac.maxX - 194, y: mac.minY + menuHeight + 66)
        let move = ramp(dropLocal, 0.65, 1.55)
        let x = mix(start.x, target.x, move), y = mix(start.y, target.y, move)
        let appear = ramp(dropLocal, 0.35, 0.6)
        let chipAlpha = appear * (1 - ramp(dropLocal, 1.55, 1.75))
        if chipAlpha > 0 {
            let chip = CGRect(x: x - 72, y: y - 19, width: 144, height: 38)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: RGB(0x090B26).cg(0.4 * chipAlpha))
            fill(chip, radius: 10, RGB(0xFFFFFF).cg(chipAlpha))
            c.restoreGState()
            c.saveGState()
            c.setAlpha(chipAlpha)
            c.addPath(rounded(CGRect(x: chip.minX + 7, y: chip.minY + 7, width: 24, height: 24), 5))
            c.clip()
            drawWallpaper(CGRect(x: chip.minX + 7, y: chip.minY + 7, width: 24, height: 24), time: wt, phase: 1)
            c.restoreGState()
            text("sunset.gif", x: chip.minX + 38, y: chip.minY + 9, width: 100, size: 15, weight: .semibold, color: RGB(0x241A4D), alpha: chipAlpha)
        }
        let leave = ramp(dropLocal, 1.9, 2.5)
        let cursorX = mix(x, mac.minX + 150, leave), cursorY = mix(y, mac.maxY - 120, leave)
        drawCursor(cursorX + 4, cursorY + 4, alpha: appear * (1 - ramp(dropLocal, 2.6, 2.9)))
    }
    c.restoreGState()
}

// MARK: Under the Mac

let strip = CGRect(x: mac.minX, y: mac.maxY + 18, width: mac.width, height: 50)

func drawRestStrip(_ t: Double, alpha: Double) {
    guard alpha > 0 else { return }
    fill(strip, radius: 25, ink.cg(0.85 * alpha))
    let paused = t >= coverStart && t < coverEnd
    let dot = paused ? haze : mint
    c.setFillColor(dot.cg(alpha))
    c.fillEllipse(in: CGRect(x: strip.minX + 24, y: strip.midY - 7, width: 14, height: 14))
    text(paused ? "Paused" : "Playing", x: strip.minX + 50, y: strip.minY + 10, width: 150, size: 24, weight: .semibold, alpha: alpha)
    text(paused ? "Processor use: 0%" : "Processor use: under 1%", x: strip.minX + 180, y: strip.minY + 10, width: strip.width - 204, size: 24, weight: .medium, color: paused ? mint : moon, alpha: alpha, align: .right)
}

func drawDayStrip(_ t: Double, alpha: Double) {
    guard alpha > 0 else { return }
    let toNight = ramp(t - restEnd, 1.2, 1.5)
    fill(strip, radius: 25, ink.cg(0.85 * alpha))
    let half = strip.width / 2
    let highlight = CGRect(x: strip.minX + 5 + CGFloat(toNight) * half, y: strip.minY + 5, width: half - 10, height: strip.height - 10)
    fill(highlight, radius: 20, RGB(0x47307F).cg(alpha))
    text("Day  7:00 AM", x: strip.minX, y: strip.minY + 11, width: half, size: 23, weight: .semibold, alpha: alpha * mix(1, 0.62, toNight), align: .center)
    text("Night  7:00 PM", x: strip.midX, y: strip.minY + 11, width: half, size: 23, weight: .semibold, alpha: alpha * mix(0.62, 1, toNight), align: .center)
}

func drawSpeedStrip(_ t: Double, alpha: Double) {
    guard alpha > 0 else { return }
    fill(strip, radius: 25, ink.cg(0.85 * alpha))
    text("Speed", x: strip.minX + 26, y: strip.minY + 10, width: 90, size: 24, weight: .semibold, alpha: alpha)
    let track = CGRect(x: strip.minX + 124, y: strip.midY - 4, width: strip.width - 250, height: 8)
    fill(track, radius: 4, RGB(0x47307F).cg(alpha))
    let speed = shownSpeed(t)
    let share = CGFloat((speed - 0.25) / 1.75)
    fill(CGRect(x: track.minX, y: track.minY, width: track.width * share, height: 8), radius: 4, peach.cg(alpha))
    c.setFillColor(moon.cg(alpha))
    c.fillEllipse(in: CGRect(x: track.minX + track.width * share - 13, y: track.midY - 13, width: 26, height: 26))
    let label = speed < 0.3 ? "0.25×" : (speed > 1.95 ? "2×" : (abs(speed - 1) < 0.05 ? "1×" : String(format: "%.1f×", speed)))
    text(label, x: strip.maxX - 106, y: strip.minY + 10, width: 84, size: 24, weight: .semibold, alpha: alpha, align: .right)
}

// MARK: The words around it

func header(alpha: Double = 1) {
    iconImage.draw(in: CGRect(x: 58, y: 28, width: 54, height: 54), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    text("Lull for Mac", x: 122, y: 37, width: 300, size: 28, weight: .semibold, alpha: alpha)
}

func footer(_ right: String?, color: RGB = haze) {
    text("Illustrated demo, not a screen recording", x: 66, y: 668, width: 520, size: 18, color: color, alpha: 0.82)
    if let right {
        text(right, x: 640, y: 668, width: 584, size: 18, color: color, alpha: 0.82, align: .right)
    }
}

func caption(_ title: String, _ note: String, start: Double, end: Double, at t: Double, titleY: CGFloat = 176) {
    let local = t - start
    let out = 1 - ramp(t, end - 0.2, end)
    let titleIn = ramp(local, 0.02, 0.3), noteIn = ramp(local, 0.12, 0.42)
    text(title, x: 64, y: titleY + CGFloat(1 - titleIn) * 12, width: 420, size: 58, weight: .bold, alpha: titleIn * out, lineHeight: 64)
    let lines = CGFloat(title.filter { $0 == "\n" }.count + 1)
    text(note, x: 66, y: titleY + lines * 64 + 26 + CGFloat(1 - noteIn) * 12, width: 400, size: 31, weight: .medium, color: haze, alpha: noteIn * out, lineHeight: 40)
}

// MARK: A frame

func draw(_ t: Double) {
    let wt = wallTime(t), p = skyPhase(t)
    if t < hookEnd || t >= speedEnd {
        drawWallpaper(CGRect(x: 0, y: 0, width: W, height: H), time: wt, phase: p)
        header()
        footer(nil, color: moon)
        if t < hookEnd {
            text("Lull", x: 62, y: 158, width: 700, size: 148, weight: .bold)
            text("GIFs and videos as\nyour Mac wallpaper", x: 66, y: 342, width: 740, size: 60, weight: .semibold, lineHeight: 72)
        } else {
            let local = t - speedEnd
            let appear = ramp(local, 0.12, 0.45), appearLate = ramp(local, 0.28, 0.6)
            text("Try Lull", x: 62, y: 134 + CGFloat(1 - appear) * 12, width: 800, size: 112, weight: .bold, alpha: appear)
            text("Free, with no account and no ads.", x: 66, y: 278 + CGFloat(1 - appear) * 12, width: 900, size: 42, weight: .semibold, alpha: appear)
            let pill = CGRect(x: 64, y: 364 + CGFloat(1 - appearLate) * 12, width: 670, height: 88)
            fill(pill, radius: 20, ink.cg(0.9 * appearLate))
            text("github.com/markoderic/lull", x: pill.minX + 32, y: pill.minY + 20, width: 640, size: 41, weight: .bold, color: peach, alpha: appearLate)
            text("Needs a Mac with an M1 chip or newer.", x: 66, y: 474 + CGFloat(1 - appearLate) * 12, width: 800, size: 28, weight: .medium, alpha: appearLate)
        }
    } else {
        let sky = CGGradient(colorsSpace: space, colors: [night.cg(), ink.cg()] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H), options: [])
        header()
        footer(t >= dropEnd && t < restEnd ? "Measured playing a GIF on an M5 Pro MacBook Pro" : "Free and open source")
        drawMac(t)

        if t < dropEnd {
            caption("Drop in\nany GIF\nor video", "It plays behind your\ndesktop icons.", start: hookEnd, end: dropEnd, at: t)
        } else if t < restEnd {
            caption("It rests when\nnobody's\nlooking", "Another app in front?\n0% processor.", start: dropEnd, end: restEnd, at: t)
            drawRestStrip(t, alpha: ramp(t - dropEnd, 0.1, 0.4) * (1 - ramp(t, restEnd - 0.2, restEnd)))
        } else if t < dayEnd {
            caption("Day and\nnight", "Pick two wallpapers\nand when they change.", start: restEnd, end: dayEnd, at: t)
            drawDayStrip(t, alpha: ramp(t - restEnd, 0.1, 0.4) * (1 - ramp(t, dayEnd - 0.2, dayEnd)))
        } else {
            caption("Your speed,\nyour FPS", "Up to 120 frames\na second.", start: dayEnd, end: speedEnd, at: t)
            drawSpeedStrip(t, alpha: ramp(t - dayEnd, 0.1, 0.4) * (1 - ramp(t, speedEnd - 0.2, speedEnd)))
        }
    }
    // Dip through the background going in and out of the little Mac.
    for boundary in [hookEnd, speedEnd] {
        let dip = 1 - clamp(abs(t - boundary) / 0.25)
        if dip > 0 { fill(CGRect(x: 0, y: 0, width: W, height: H), night.cg(dip)) }
    }
}

func savePNG(to path: String) throws {
    NSGraphicsContext.current?.flushGraphics()
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func runFFmpeg(_ arguments: [String], input: Pipe? = nil) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + arguments
    if let input { process.standardInput = input }
    try process.run()
    return process
}

// MARK: Run

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--still", arguments.count == 3, let t = Double(arguments[1]) {
    draw(t)
    try savePNG(to: arguments[2])
    exit(0)
}

let folder = arguments.first ?? "docs/media"
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
let mp4 = "\(folder)/lull-demo.mp4"
let pipe = Pipe()
let encoder = try runFFmpeg([
    "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)", "-r", String(Int(fps)), "-i", "-",
    "-vf", "scale=out_color_matrix=bt709", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
    "-c:v", "libx264", "-crf", "20", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4,
], input: pipe)
let frames = Int(total * fps)
for frame in 0..<frames {
    autoreleasepool {
        draw(Double(frame) / fps)
        NSGraphicsContext.current?.flushGraphics()
        let data = Data(bytes: c.data!, count: width * height * 4)
        pipe.fileHandleForWriting.write(data)
    }
}
try pipe.fileHandleForWriting.close()
encoder.waitUntilExit()

let gif = try runFFmpeg([
    "-i", mp4, "-vf",
    // Better colour is possible with a palette per frame, but that makes an 18 MB file.
    "fps=12,scale=800:450:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle",
    "\(folder)/lull-demo.gif",
])
gif.waitUntilExit()

draw(9)
try savePNG(to: "\(folder)/lull-demo.png")
