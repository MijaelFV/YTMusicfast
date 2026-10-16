import AppKit

// Windows and Linux icons from the Mac app icon (the 1024 px PNG in AppIcon.appiconset):
//
//   swift desktop/packaging/make-icons.swift
//
// writes desktop/packaging/icons/ytmusicfast.ico (16–256 px; 256 as PNG, the rest as 32-bit BMP
// so every Windows shell and resource tool reads it) and the freedesktop hicolor PNGs
// (16–512 px) used by the AppImage and the Flatpak. Run it again after changing the Mac icon.
//
// The Mac icon keeps Apple's 100 px margin around the squircle; Windows and Linux icons fill
// more of the canvas, so the source is cropped to the squircle and its shadow first.

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // desktop/packaging
let repo = root.deletingLastPathComponent().deletingLastPathComponent()
let source = repo.appendingPathComponent("YTMusicfast/Resources/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png")
let appID = "io.github.mijaelfv.YTMusicfast"

guard let master = NSBitmapImageRep(data: try Data(contentsOf: source)), master.pixelsWide == 1024 else {
    fatalError("expected a 1024 px icon at \(source.path)")
}
// The squircle spans 100…924 and its shadow reaches ~964 (top-left origin): keep 56…968.
let crop = NSRect(x: 56, y: 1024 - 968, width: 912, height: 912)  // AppKit's origin is bottom-left

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bitmapFormat: [], bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: crop, operation: .copy,
                fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

/// An ICO image entry as a BITMAPINFOHEADER DIB: bottom-up BGRA rows, then the 1-bit AND mask.
func dib(_ rep: NSBitmapImageRep) -> Data {
    let size = rep.pixelsWide
    var data = Data()
    func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    le(UInt32(40)); le(Int32(size)); le(Int32(size * 2)); le(UInt16(1)); le(UInt16(32))
    le(UInt32(0)); le(UInt32(0)); le(Int32(0)); le(Int32(0)); le(UInt32(0)); le(UInt32(0))
    let pixels = rep.bitmapData!
    let stride = rep.bytesPerRow
    for y in (0..<size).reversed() {
        for x in 0..<size {
            let p = pixels + y * stride + x * 4  // premultiplied RGBA
            let a = p[3]
            func unpremultiply(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a))) }
            data.append(contentsOf: [unpremultiply(p[2]), unpremultiply(p[1]), unpremultiply(p[0]), a])
        }
    }
    let maskRow = ((size + 31) / 32) * 4
    for y in (0..<size).reversed() {
        var row = [UInt8](repeating: 0, count: maskRow)
        for x in 0..<size where (pixels + y * stride + x * 4)[3] == 0 { row[x / 8] |= 0x80 >> UInt8(x % 8) }
        data.append(contentsOf: row)
    }
    return data
}

let icons = root.appendingPathComponent("icons")
let fm = FileManager.default

// Windows: the sizes Explorer, the taskbar and the Start menu ask for at 100–200% scaling.
let icoSizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
let images = icoSizes.map { $0 == 256 ? png(render($0)) : dib(render($0)) }
var ico = Data()
func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { ico.append(contentsOf: $0) } }
le(UInt16(0)); le(UInt16(1)); le(UInt16(icoSizes.count))
var offset = 6 + 16 * icoSizes.count
for (size, image) in zip(icoSizes, images) {
    ico.append(UInt8(size == 256 ? 0 : size)); ico.append(UInt8(size == 256 ? 0 : size))
    ico.append(0); ico.append(0)
    le(UInt16(1)); le(UInt16(32)); le(UInt32(image.count)); le(UInt32(offset))
    offset += image.count
}
images.forEach { ico.append($0) }
try fm.createDirectory(at: icons, withIntermediateDirectories: true)
try ico.write(to: icons.appendingPathComponent("ytmusicfast.ico"))

// Linux: the hicolor theme sizes; Flathub needs at least 128 px, 256 px or more is recommended.
for size in [16, 24, 32, 48, 64, 128, 256, 512] {
    let dir = icons.appendingPathComponent("hicolor/\(size)x\(size)/apps")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try png(render(size)).write(to: dir.appendingPathComponent("\(appID).png"))
}
print("Wrote \(icons.path)")
