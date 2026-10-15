import AppKit
import ImageIO
import SwiftUI

enum Artwork {
    /// YouTube Music artwork URLs embed their size (`=w120-h120-...`); rewrite it to fetch the
    /// resolution we actually display instead of upscaling a thumbnail.
    static func url(_ url: URL?, size: Int) -> URL? {
        guard let url else { return nil }
        // Every cover asks on every render; remember answers instead of re-running the patterns.
        let key = "\(size)|\(url.absoluteString)" as NSString
        if let known = resolvedCache.object(forKey: key) { return known as URL }
        let resolved = rewrite(url, size: size)
        resolvedCache.setObject(resolved as NSURL, forKey: key)
        return resolved
    }

    private nonisolated(unsafe) static let resolvedCache: NSCache<NSString, NSURL> = {
        let cache = NSCache<NSString, NSURL>()
        cache.countLimit = 4000
        return cache
    }()

    private static func rewrite(_ url: URL, size: Int) -> URL {
        let string = url.absoluteString
        let px = size * 2
        if let range = string.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return URL(string: string.replacingCharacters(in: range, with: "=w\(px)-h\(px)")) ?? url
        }
        if let range = string.range(of: #"=s\d+"#, options: .regularExpression) {
            return URL(string: string.replacingCharacters(in: range, with: "=s\(px)")) ?? url
        }
        return url
    }
}

/// Memory + disk cached image loading with request coalescing.
actor ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSURL, NSImage>()
    /// Latest image per artwork regardless of requested size, shown while a sharper copy loads.
    private nonisolated(unsafe) static let anySize = NSCache<NSString, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private var colors: [URL: NSColor] = [:]
    private let session: URLSession

    init() {
        // Bound decoded images by bytes, not count: a few big banners shouldn't pin memory.
        memory.totalCostLimit = 60 << 20
        memory.countLimit = 500
        Self.anySize.totalCostLimit = 20 << 20
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20,
                                   directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                       .appendingPathComponent("YTMusicfast/images"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    nonisolated func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Approximate decoded size in bytes.
    private nonisolated static func cost(of image: NSImage) -> Int {
        let rep = image.representations.first
        let width = rep?.pixelsWide ?? Int(image.size.width)
        let height = rep?.pixelsHigh ?? Int(image.size.height)
        return max(1, width * height * 4)
    }

    nonisolated func cachedAnySize(_ url: URL) -> NSImage? {
        Self.anySize.object(forKey: Self.baseKey(url))
    }

    private nonisolated static func baseKey(_ url: URL) -> NSString {
        url.absoluteString.replacingOccurrences(of: #"=(w\d+-h\d+|s\d+).*$"#, with: "", options: .regularExpression) as NSString
    }

    func image(for url: URL) async -> NSImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        if let task = inFlight[url] { return await task.value }
        let session = self.session
        // Detached so decoding runs in parallel, off this actor and off the main thread.
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.decode(data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let cost = Self.cost(of: image)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
            Self.anySize.setObject(image, forKey: Self.baseKey(url), cost: cost)
        }
        return image
    }

    /// Decodes now. `NSImage(data:)` defers decoding to the first draw, which happens on the main
    /// thread and made new rows stutter as they scrolled in.
    ///
    /// Drawing into our own bitmap is what makes it stick: on Apple Silicon a JPEG otherwise stays
    /// "lazy" and gets hardware-decoded and rescaled during the frame commit, on the main thread.
    private nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return NSImage(data: data) }
        let width = image.width, height = image.height
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        // BGRA in native byte order: what the compositor takes without converting.
        let alpha = opaque ? CGImageAlphaInfo.noneSkipFirst : .premultipliedFirst
        guard let space = targetColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return NSImage(cgImage: image, size: NSSize(width: width, height: height)) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bitmap = context.makeImage() else { return NSImage(cgImage: image, size: NSSize(width: width, height: height)) }
        return NSImage(cgImage: bitmap, size: NSSize(width: width, height: height))
    }

    /// The screen's colour space, so images arrive already converted (on a wide-colour display the
    /// compositor otherwise converts each sRGB cover on the main thread as it's drawn).
    nonisolated(unsafe) static var targetColorSpace: CGColorSpace?

    /// Average colour of the artwork, used to tint page headers and the full-screen player.
    func averageColor(for url: URL) async -> NSColor? {
        if let color = colors[url] { return color }
        guard let image = await image(for: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .medium
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        colors[url] = color
        return color
    }
}

struct ArtworkView: View {
    var url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 6
    var circle = false
    /// Fill the proposed frame instead of a fixed `size` square (used for animated transitions).
    var resizable = false

    @State private var image: NSImage?

    /// Large covers are requested in 40pt steps, so cards that resize with the window reuse
    /// the image they have instead of downloading one for every width.
    private var resolved: URL? {
        Artwork.url(url, size: size >= 120 ? Int((size / 40).rounded(.up) * 40) : Int(size))
    }

    var body: some View {
        // The placeholder defines the square; the image is laid over it and clipped, so wide
        // (16:9 video) thumbnails can never spill outside their frame.
        Rectangle()
            .fill(Theme.elevated)
            .frame(width: resizable ? nil : size, height: resizable ? nil : size)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = image ?? resolved.flatMap({ ImageLoader.shared.cached($0) ?? ImageLoader.shared.cachedAnySize($0) }) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: max(10, size * 0.3)))
                        .foregroundStyle(Theme.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .task(id: resolved) {
            guard let resolved else { image = nil; return }
            if let cached = ImageLoader.shared.cached(resolved) { image = cached; return }
            // Never keep showing the previous artwork while the new one loads.
            image = ImageLoader.shared.cachedAnySize(resolved)
            // No fade-in: in a fast scroll, dozens of covers arrive at once and SwiftUI animates
            // each fade on the main thread, frame by frame.
            image = await ImageLoader.shared.image(for: resolved)
        }
    }
}

/// Resolves the dominant artwork colour for header gradients.
struct ArtworkTint: ViewModifier {
    var url: URL?
    @Binding var color: Color

    func body(content: Content) -> some View {
        content.task(id: url) {
            guard let url = Artwork.url(url, size: 60), let ns = await ImageLoader.shared.averageColor(for: url) else { return }
            withAnimation(.easeInOut(duration: 0.4)) { color = Color(nsColor: ns) }
        }
    }
}

extension View {
    func artworkTint(_ url: URL?, into color: Binding<Color>) -> some View {
        modifier(ArtworkTint(url: url, color: color))
    }
}
