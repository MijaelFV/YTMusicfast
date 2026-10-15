import AppKit
import os
import QuartzCore
import SwiftUI

/// Timing milestones (launch, Home shown, click to sound), read with
/// `log stream --predicate 'subsystem == "dev.ytmusicfast" AND category == "Perf"'` (see docs/performance.md).
let perfLog = Logger(subsystem: "dev.ytmusicfast", category: "Perf")

/// Temporary measuring tool. A copy of the app launched with `YTMF_BENCH=1` (and
/// `YTMF_BENCH_TARGET=<playlist browseId>`) scrolls Home, then that playlist, one step per display
/// refresh, logs how long the main thread was busy each frame, and quits.
enum Bench {
    static let enabled = ProcessInfo.processInfo.environment["YTMF_BENCH"] != nil
    static let target = ProcessInfo.processInfo.environment["YTMF_BENCH_TARGET"]
    /// Points per second; a rushed user's hard flick is well over 5000.
    static let speed = ProcessInfo.processInfo.environment["YTMF_BENCH_SPEED"].flatMap(Double.init) ?? 2000
    /// "page" skips Home and goes straight to the playlist.
    static let only = ProcessInfo.processInfo.environment["YTMF_BENCH_ONLY"]
    /// "stack" or "list": render just the song rows, to compare the two containers.
    static let variant = ProcessInfo.processInfo.environment["YTMF_BENCH_VARIANT"]

    static func log(_ line: String) {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }

    /// From launch: logs any main-thread pass over 25 ms (page loads, navigation), not just while scrolling.
    @MainActor static func installSlowLogger() {
        guard enabled else { return }
        let launch = CACurrentMediaTime()
        var wokeAt: CFTimeInterval = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { wokeAt = now } else if wokeAt > 0, now - wokeAt > 0.025 {
                log(String(format: "PASS launch+%.2fs %.1fms", wokeAt - launch, (now - wokeAt) * 1000))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Seconds since the measurement began, for lining events up with slow frames.
    @MainActor static var clockStart: CFTimeInterval = 0
    @MainActor static func event(_ what: String) {
        guard enabled, clockStart > 0 else { return }
        log(String(format: "EVENT t=%.3f %@", CACurrentMediaTime() - clockStart, what))
    }
}

struct ScrollBench: ViewModifier {
    var name: String
    var ready: Bool

    func body(content: Content) -> some View {
        if Bench.enabled {
            content
                .task(id: ready) {
                    guard ready else { return }
                    if name == "home", Bench.only == "library" {
                        guard !Self.started.contains("library") else { return }
                        Self.started.insert("library")
                        try? await Task.sleep(for: .seconds(3))
                        guard let library = Self.scrollViews().min(by: { Self.minX($0) < Self.minX($1) }) else { return }
                        await Self.measure("library", library)
                        NSApp.terminate(nil)
                        return
                    }
                    if name == "home", Bench.only == "page", let target = Bench.target {
                        Router.shared.open(BrowseTarget(browseId: target, kind: .playlist, title: "Bench"))
                        return
                    }
                    // Once per name: the view can report "ready" more than once.
                    guard !Self.started.contains(name) else { return }
                    Self.started.insert(name)
                    try? await Task.sleep(for: .seconds(3))
                    // Scroll the page's AppKit scroll view directly, like a trackpad does.
                    guard let scrollView = Self.mainScrollView() else { Bench.log("BENCH no scroll view"); return }
                    await FrameDriver(name: name).run(seconds: 10) { t in
                        // Down for half the time, then back up, at a steady flick speed.
                        let speed = CGFloat(Bench.speed)
                        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
                        let y = min(maxY, t < 5 ? speed * t : max(0, speed * (10 - t)))
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                    try? await Task.sleep(for: .seconds(1))
                    if name == "home", let target = Bench.target {
                        Router.shared.open(BrowseTarget(browseId: target, kind: .playlist, title: "Bench"))
                    } else {
                        NSApp.terminate(nil)
                    }
                }
        } else {
            content
        }
    }
}

/// Measures, while scrolling: how long the main thread works per run-loop pass (a frame can't be
/// on time if that exceeds the refresh interval), and how regularly display refreshes arrive.
@MainActor
private final class FrameDriver: NSObject {
    let name: String
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var wokeAt: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var busy: [Double] = []
    private var frameDuration: Double = 1.0 / 60
    private var seconds: Double = 0
    private var step: ((CGFloat) -> Void)?
    private var done: CheckedContinuation<Void, Never>?

    init(name: String) { self.name = name }

    func run(seconds: Double, step: @escaping (CGFloat) -> Void) async {
        self.seconds = seconds
        self.step = step
        // Programmatic scrolling has no scroll phase; flag it the way a real scroll would.
        ScrollActivity.shared.isScrolling = true
        defer { ScrollActivity.shared.isScrolling = false }
        let screen = NSApp.windows.first { $0.isVisible && $0.title == "YT Musicfast" }?.screen ?? NSScreen.main
        guard let screen else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self, self.start > 0 else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { self.wokeAt = now } else if self.wokeAt > 0 {
                    let spent = now - self.wokeAt
                    self.busy.append(spent)
                    if spent > 0.012 { Bench.log(String(format: "SLOW t=%.3f %.1fms", self.wokeAt - self.start, spent * 1000)) }
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        await withCheckedContinuation { continuation in
            done = continuation
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if start == 0 {
            start = now
            Bench.clockStart = now
            last = now
            frameDuration = link.targetTimestamp - link.timestamp
        } else {
            intervals.append(now - last)
            last = now
        }
        let t = now - start
        if t >= seconds {
            link.invalidate()
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            report()
            done?.resume()
            done = nil
            return
        }
        step?(CGFloat(t))
    }

    private func report() {
        func stats(_ values: [Double]) -> String {
            let s = values.sorted()
            guard !s.isEmpty else { return "n=0" }
            let ms = { (v: Double) in String(format: "%.1f", v * 1000) }
            return "p50=\(ms(s[s.count / 2])) p95=\(ms(s[Int(Double(s.count) * 0.95)])) p99=\(ms(s[Int(Double(s.count) * 0.99)])) max=\(ms(s.last!))"
        }
        let over8 = busy.filter { $0 > 1.0 / 120 }.count
        let over13 = busy.filter { $0 > 1.0 / 75 }.count
        let late = intervals.filter { $0 > frameDuration * 1.5 }.count
        let window = NSApp.windows.first { $0.isVisible && $0.title == "YT Musicfast" }
        let screen = window?.screen
        Bench.log("WINDOW screen=\(screen?.localizedName ?? "?") scale=\(screen?.backingScaleFactor ?? 0) maxfps=\(screen?.maximumFramesPerSecond ?? 0) visible=\(window?.occlusionState.contains(.visible) ?? false) frame=\(window.map { NSStringFromRect($0.frame) } ?? "?")")
        Bench.log("BENCH \(name) hz=\(Int((1 / frameDuration).rounded())) busy[\(stats(busy))] >8ms=\(over8) >13ms=\(over13) totalBusy=\(String(format: "%.0f", busy.reduce(0, +) * 1000))ms"
                  + " | refresh[\(stats(intervals))] late=\(late)")
    }
}

extension ScrollBench {
    @MainActor static var started: Set<String> = []

    /// The widest visible scroll view: the main panel (the library and queue are narrower).
    @MainActor static func mainScrollView() -> NSScrollView? {
        scrollViews().max { $0.frame.width < $1.frame.width }
    }

    @MainActor static func scrollViews() -> [NSScrollView] {
        guard let root = NSApp.windows.first(where: { $0.isVisible && $0.title == "YT Musicfast" })?.contentView else { return [] }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden, scroll.frame.height > 200 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    @MainActor static func minX(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).minX }

    @MainActor static func measure(_ name: String, _ scrollView: NSScrollView) async {
        await FrameDriver(name: name).run(seconds: 10) { t in
            let speed = CGFloat(Bench.speed)
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
            let y = min(maxY, t < 5 ? speed * t : max(0, speed * (10 - t)))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

extension View {
    func scrollBench(_ name: String, ready: Bool) -> some View {
        modifier(ScrollBench(name: name, ready: ready))
    }
}

/// Experiment: identical rows, in a LazyVStack (what pages use) or in a native List.
struct BenchListExperiment: View {
    var variant: String
    var tracks: [Track]
    var loadMore: () -> Void

    var body: some View {
        if variant == "list" {
            List {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track, index: index) {}
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .onAppear { if index == tracks.count - 1 { loadMore() } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 56)
        } else {
            ScrollView {
                TrackList(tracks: tracks, onLoadMore: loadMore)
            }
        }
    }
}
