import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: a) }
func grad(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }

// 4-point sparkle with concave sides
func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ R: CGFloat) -> CGPath {
    let p = CGMutablePath(); let k = R * 0.18
    p.move(to: CGPoint(x: cx, y: cy + R))
    p.addQuadCurve(to: CGPoint(x: cx + R, y: cy), control: CGPoint(x: cx + k, y: cy + k))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy - R), control: CGPoint(x: cx + k, y: cy - k))
    p.addQuadCurve(to: CGPoint(x: cx - R, y: cy), control: CGPoint(x: cx - k, y: cy - k))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy + R), control: CGPoint(x: cx - k, y: cy + k))
    return p
}

// --- Background squircle (Apple grid: 824pt body, 100pt margin)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: c(0, 0, 0, 0.30))
ctx.addPath(bodyPath); ctx.setFillColor(c(40, 60, 200)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(grad([c(112, 178, 255), c(72, 110, 250), c(88, 62, 214)], [0, 0.55, 1]),
                       start: CGPoint(x: 230, y: 924), end: CGPoint(x: 800, y: 100), options: [])
// soft top glow
ctx.drawRadialGradient(grad([c(255, 255, 255, 0.35), c(255, 255, 255, 0)]),
                       startCenter: CGPoint(x: 360, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 860), endRadius: 560, options: [])
ctx.restoreGState()

// --- Dashed "empty slot" left behind
let slot = CGRect(x: 238, y: 214, width: 400, height: 400)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: slot, cornerWidth: 96, cornerHeight: 96, transform: nil))
ctx.setStrokeColor(c(255, 255, 255, 0.55)); ctx.setLineWidth(22); ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [52, 40]); ctx.strokePath()
ctx.restoreGState()

// --- App tile lifting out, tilted
ctx.saveGState()
ctx.translateBy(x: 560, y: 520); ctx.rotate(by: -0.20)
let tile = CGRect(x: -200, y: -200, width: 400, height: 400)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 96, cornerHeight: 96, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -18, height: -34), blur: 60, color: c(20, 10, 90, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(c(255, 255, 255)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(grad([c(255, 255, 255), c(226, 234, 255)]),
                       start: CGPoint(x: 0, y: 200), end: CGPoint(x: 0, y: -200), options: [])
ctx.restoreGState()
// sparkle glyph on tile
ctx.saveGState()
ctx.addPath(sparkle(-10, 10, 128)); ctx.addPath(sparkle(92, 104, 44)); ctx.clip()
ctx.drawLinearGradient(grad([c(96, 160, 255), c(98, 70, 230)]),
                       start: CGPoint(x: -140, y: 150), end: CGPoint(x: 140, y: -130), options: [])
ctx.restoreGState()
ctx.restoreGState()

// --- Floating sparkles around
for (x, y, r, a) in [(300.0, 760.0, 46.0, 0.95), (820.0, 300.0, 34.0, 0.85), (230.0, 180.0, 0.0, 0)] where r > 0 {
    ctx.addPath(sparkle(x, y, r)); ctx.setFillColor(c(255, 255, 255, a)); ctx.fillPath()
}
ctx.addEllipse(in: CGRect(x: 760, y: 790, width: 22, height: 22)); ctx.setFillColor(c(255, 255, 255, 0.7)); ctx.fillPath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
