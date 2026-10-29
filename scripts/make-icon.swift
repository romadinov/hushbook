import AppKit
import ImageIO
import UniformTypeIdentifiers
// Usage: swift scripts/make-icon.swift <appiconset dir>
// Draws the Hushbook icon in Uberdoer's style: dark navy tile with a blue glowing rim, a glossy blue journal with
// stacked pages behind it, and a cyan-to-mint padlock. iOS gets the opaque full-bleed tile (iOS masks it);
// macOS gets the 824 px rounded tile on a transparent 1024 canvas.

let out = CommandLine.arguments[1]
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Fills `path` with a linear gradient from `from` to `to` (points in the 1024 design space, y down).
func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// The artwork in a 1024×1024 design space with y pointing down.
func drawTile(_ ctx: CGContext, cornerRadius: CGFloat) {
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let tile = rounded(full, cornerRadius)

    // Background: deep navy with a faint blue bloom in the middle.
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.setFillColor(rgb(0x070C1A)); ctx.fill(full)
    ctx.drawRadialGradient(gradient([rgb(0x15306E, 0.85), rgb(0x0A1430, 0.4), rgb(0x070C1A, 0)]),
                           startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 500), endRadius: 560, options: [])
    // Glowing rim.
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x2F7BFF, 0.9))
    ctx.setStrokeColor(rgb(0x2C6BF0, 0.85))
    ctx.setLineWidth(10)
    ctx.addPath(rounded(full.insetBy(dx: 8, dy: 8), max(cornerRadius - 8, 0)))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    // Tilt the journal slightly, like Uberdoer's cards.
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -0.10)
    ctx.translateBy(x: -512, y: -512)

    // Pages stacked behind the cover.
    let back = [(CGFloat(56), rgb(0x3A2FD8), rgb(0x2B48E6)), (CGFloat(28), rgb(0x2C4BEB), rgb(0x2F6BF2))]
    for (offset, c1, c2) in back {
        let r = CGRect(x: 250 + offset, y: 200 + offset, width: 540, height: 620)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: rgb(0x000000, 0.55))
        ctx.addPath(rounded(r, 56)); ctx.setFillColor(c2); ctx.fillPath()
        ctx.restoreGState()
        fill(ctx, rounded(r, 56), gradient([c2, c1]), from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
        // Light page edge along the right and bottom.
        ctx.saveGState()
        ctx.addPath(rounded(r, 56)); ctx.setStrokeColor(rgb(0x6FA8FF, 0.45)); ctx.setLineWidth(5); ctx.strokePath()
        ctx.restoreGState()
    }

    // Cover with glow.
    let cover = CGRect(x: 236, y: 186, width: 540, height: 620)
    let coverPath = rounded(cover, 60)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 60, color: rgb(0x1E7BFF, 0.65))
    ctx.addPath(coverPath); ctx.setFillColor(rgb(0x2F8DF5)); ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, coverPath, gradient([rgb(0x46C2FF), rgb(0x2E8EF7), rgb(0x2A55EC)], [0, 0.5, 1]),
         from: CGPoint(x: cover.minX, y: cover.minY), to: CGPoint(x: cover.maxX, y: cover.maxY))

    // Spine band.
    let spine = CGRect(x: cover.minX, y: cover.minY, width: 96, height: cover.height)
    ctx.saveGState()
    ctx.addPath(coverPath); ctx.clip()
    fill(ctx, CGPath(rect: spine, transform: nil), gradient([rgb(0x1F5FE0, 0.95), rgb(0x2448D2, 0.95)]),
         from: CGPoint(x: spine.minX, y: spine.minY), to: CGPoint(x: spine.maxX, y: spine.maxY))
    ctx.setStrokeColor(rgb(0x9FDBFF, 0.55)); ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: spine.maxX, y: cover.minY)); ctx.addLine(to: CGPoint(x: spine.maxX, y: cover.maxY)); ctx.strokePath()
    // Soft top gloss.
    fill(ctx, coverPath, gradient([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)]),
         from: CGPoint(x: 0, y: cover.minY), to: CGPoint(x: 0, y: cover.minY + 260))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(coverPath); ctx.setStrokeColor(rgb(0xBFE8FF, 0.55)); ctx.setLineWidth(5); ctx.strokePath()
    ctx.restoreGState()

    // Padlock, raised and glossy like Uberdoer's check mark.
    let cx: CGFloat = 548
    let body = CGRect(x: cx - 150, y: 470, width: 300, height: 230)
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: cx - 95, y: 480))
    shackle.addLine(to: CGPoint(x: cx - 95, y: 400))
    shackle.addArc(center: CGPoint(x: cx, y: 400), radius: 95, startAngle: .pi, endAngle: 0, clockwise: false)
    shackle.addLine(to: CGPoint(x: cx + 95, y: 480))
    let shacklePath = shackle.copy(strokingWithWidth: 52, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let lock = shacklePath.union(rounded(body, 54))

    let lockGradient = gradient([rgb(0x5BF2B6), rgb(0x6FE6FF), rgb(0x56B8FF)], [0, 0.45, 1])
    // Extruded edge underneath.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 14)
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: rgb(0x0A1F7A, 0.7))
    ctx.addPath(lock); ctx.setFillColor(rgb(0x2346C8)); ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, lock, lockGradient, from: CGPoint(x: cx + 170, y: 300), to: CGPoint(x: cx - 120, y: 720))
    // Gloss on the upper half.
    ctx.saveGState()
    ctx.addPath(lock); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0.0)]),
                           start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 560), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(lock); ctx.setStrokeColor(rgb(0xE6FFFA, 0.6)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()

    // Keyhole.
    let hole = CGMutablePath()
    hole.addEllipse(in: CGRect(x: cx - 34, y: 540, width: 68, height: 68))
    hole.move(to: CGPoint(x: cx - 18, y: 590))
    hole.addLine(to: CGPoint(x: cx + 18, y: 590))
    hole.addLine(to: CGPoint(x: cx + 26, y: 655))
    hole.addLine(to: CGPoint(x: cx - 26, y: 655))
    hole.closeSubpath()
    fill(ctx, hole, gradient([rgb(0x1A3BB5), rgb(0x22308F)]), from: CGPoint(x: 0, y: 540), to: CGPoint(x: 0, y: 655))
    ctx.restoreGState()
}

func render(_ size: Int, mac: Bool) -> CGImage {
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size)
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)               // y down, like the design space
    if mac {
        let shape = s * 824 / 1024
        ctx.translateBy(x: (s - shape) / 2, y: (s - shape) / 2)
        ctx.scaleBy(x: shape / 1024, y: shape / 1024)
        drawTile(ctx, cornerRadius: 1024 * 0.2237)
    } else {
        ctx.scaleBy(x: s / 1024, y: s / 1024)
        drawTile(ctx, cornerRadius: 0)
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/\(name)") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

write(render(1024, mac: false), "icon-1024.png")
for s in [16, 32, 64, 128, 256, 512, 1024] { write(render(s, mac: true), "mac-\(s).png") }
