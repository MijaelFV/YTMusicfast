import AppKit

// 1024×1024 macOS app icon: dark rounded square, red disc with a white play triangle, and
// speed streaks trailing off to the left ("fast").
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// Background squircle (Apple's grid: 824pt body, 100pt margin).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(squircle); ctx.setFillColor(rgb(0.07, 0.07, 0.08)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0.17, 0.17, 0.19), rgb(0.04, 0.04, 0.05)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft red glow behind the disc.
let glow = CGGradient(colorsSpace: space, colors: [rgb(1, 0.1, 0.1, 0.35), rgb(1, 0.1, 0.1, 0)] as CFArray, locations: [0, 1])!
let center = CGPoint(x: 560, y: 512)
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 430, options: [])

// Speed streaks, left of the disc: they fade in from the left and tuck under it.
for (y, length, alpha) in [(600.0, 150.0, 0.85), (512.0, 200.0, 1.0), (424.0, 150.0, 0.85)] as [(CGFloat, CGFloat, CGFloat)] {
    let end = center.x - 230
    let start = end - length
    let streak = CGGradient(colorsSpace: space, colors: [rgb(1, 0.3, 0.3, 0), rgb(1, 0.22, 0.2, alpha)] as CFArray, locations: [0, 0.8])!
    let path = CGMutablePath()
    path.move(to: CGPoint(x: start, y: y)); path.addLine(to: CGPoint(x: end, y: y))
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: 30, lineCap: .round, lineJoin: .round, miterLimit: 1)); ctx.clip()
    ctx.drawLinearGradient(streak, start: CGPoint(x: start - 15, y: y), end: CGPoint(x: end + 15, y: y), options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

// Red disc.
let radius: CGFloat = 270
let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0.5, 0, 0, 0.6))
ctx.addEllipse(in: disc); ctx.setFillColor(rgb(0.95, 0.05, 0.08)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: disc); ctx.clip()
let red = CGGradient(colorsSpace: space, colors: [rgb(1, 0.27, 0.22), rgb(0.93, 0.02, 0.07), rgb(0.72, 0, 0.1)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(red, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
ctx.restoreGState()

// White ring.
let ring = disc.insetBy(dx: 72, dy: 72)
ctx.addEllipse(in: ring); ctx.setStrokeColor(rgb(1, 1, 1)); ctx.setLineWidth(26); ctx.strokePath()

// White play triangle with rounded corners, nudged right to look centred.
let tri = CGMutablePath()
let h: CGFloat = 170, w: CGFloat = 150, cx = center.x + 14
let p1 = CGPoint(x: cx - w / 2, y: center.y + h / 2), p2 = CGPoint(x: cx + w / 2, y: center.y), p3 = CGPoint(x: cx - w / 2, y: center.y - h / 2)
tri.move(to: CGPoint(x: (p1.x + p3.x) / 2, y: (p1.y + p3.y) / 2))
tri.addArc(tangent1End: p1, tangent2End: p2, radius: 22)
tri.addArc(tangent1End: p2, tangent2End: p3, radius: 22)
tri.addArc(tangent1End: p3, tangent2End: p1, radius: 22)
tri.closeSubpath()
ctx.addPath(tri); ctx.setFillColor(rgb(1, 1, 1)); ctx.fillPath()
ctx.restoreGState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
