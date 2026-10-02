import AppKit

// Renders Lumen's icon: an amber sun rising over a frosted display bezel on a
// deep indigo field, in the macOS 26 squircle grid (824pt body in 1024 canvas).
func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let rgb = CGColorSpace(name: CGColorSpace.displayP3)!

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Background: indigo → near-black
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: rgb, colors: [CGColor(red: 0.20, green: 0.17, blue: 0.48, alpha: 1),
                                                   CGColor(red: 0.04, green: 0.04, blue: 0.10, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Sun glow
    let sun = CGPoint(x: 640, y: 610)
    let glow = CGGradient(colorsSpace: rgb, colors: [CGColor(red: 1, green: 0.72, blue: 0.25, alpha: 0.55),
                                                     CGColor(red: 1, green: 0.45, blue: 0.10, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 420, options: [])

    // Rays
    ctx.setLineCap(.round)
    for i in 0..<12 {
        let a = CGFloat(i) / 12 * 2 * .pi
        ctx.move(to: CGPoint(x: sun.x + cos(a) * 165, y: sun.y + sin(a) * 165))
        ctx.addLine(to: CGPoint(x: sun.x + cos(a) * 225, y: sun.y + sin(a) * 225))
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 0.80, blue: 0.40, alpha: 0.9)); ctx.setLineWidth(26); ctx.strokePath()

    // Sun disc
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sun.x - 130, y: sun.y - 130, width: 260, height: 260)); ctx.clip()
    let disc = CGGradient(colorsSpace: rgb, colors: [CGColor(red: 1, green: 0.95, blue: 0.75, alpha: 1),
                                                     CGColor(red: 1, green: 0.62, blue: 0.16, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(disc, start: CGPoint(x: sun.x - 80, y: sun.y + 130), end: CGPoint(x: sun.x + 80, y: sun.y - 130), options: [])
    ctx.restoreGState()

    // Frosted display bezel overlapping the sun
    let screen = CGRect(x: 220, y: 300, width: 500, height: 330)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.addPath(screenPath); ctx.setFillColor(CGColor(red: 0.16, green: 0.14, blue: 0.36, alpha: 0.72)); ctx.fillPath()
    ctx.addPath(screenPath); ctx.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 1, alpha: 0.10)); ctx.fillPath()
    ctx.addPath(screenPath); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85)); ctx.setLineWidth(18); ctx.strokePath()
    // Brightness meter inside the screen
    let track = CGRect(x: 280, y: 440, width: 380, height: 34)
    ctx.addPath(CGPath(roundedRect: track, cornerWidth: 17, cornerHeight: 17, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.18)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 280, y: 440, width: 270, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.95)); ctx.fillPath()
    // Stand
    ctx.addPath(CGPath(roundedRect: CGRect(x: 410, y: 222, width: 120, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.move(to: CGPoint(x: 470, y: 291)); ctx.addLine(to: CGPoint(x: 470, y: 244))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85)); ctx.setLineWidth(18); ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 410, y: 222, width: 120, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.85)); ctx.fillPath()

    // Top specular rim
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
